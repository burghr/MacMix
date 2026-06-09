// This file is part of MacMixer, a fork of Background Music.
// Copyright © 2026 burghr
//
// MacMixer is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 2 of the License, or (at your option)
// any later version.
//
// MacMixer is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for details.

//
//  MixerEngine.mm
//  MacMixer
//

// Self Include
#import "MixerEngine.h"

// BGM Core
#import "BGMAudioDeviceManager.h"
#import "BGMBackgroundMusicDevice.h"
#import "BGMXPCListener.h"
#import "BGM_Types.h"

// PublicUtility
#import "CAHALAudioSystemObject.h"
#import "CAHALAudioDevice.h"
#import "CAException.h"

// System
#import <AVFoundation/AVCaptureDevice.h>
#import <vector>

#pragma clang assume_nonnull begin

// kScope: the output scope. kMasterChannel comes from BGM_Types.h.
static const AudioObjectPropertyScope kScope = kAudioDevicePropertyScopeOutput;

// BGM's per-app "relative volume" is raw 0..100 where the MIDPOINT (50) is unity
// gain — the app's normal volume. Above 50 boosts (up to ~4x at 100), below 50
// attenuates to silence at 0. Apps with no custom volume sit at unity, and the
// driver omits them from the app-volumes array, so "not found" means neutral.
static const int kMixerNeutralRawVolume =
    (kAppRelativeVolumeMaxRawValue + kAppRelativeVolumeMinRawValue) / 2;

// ── MixerOutputDevice ──────────────────────────────────────────────────────

@implementation MixerOutputDevice
- (instancetype)initWithID:(AudioObjectID)deviceID name:(NSString *)name {
    if ((self = [super init])) {
        _deviceID = deviceID;
        _name = [name copy];
    }
    return self;
}
@end

// ── MixerEngine ─────────────────────────────────────────────────────────────

@implementation MixerEngine {
    BGMAudioDeviceManager *_manager;
    BGMXPCListener *_xpcListener;
    BOOL _running;

    // Listens for the output device's nominal sample rate changing so we can
    // re-sync playthrough (avoids slow-mo audio when e.g. AirPods drop to a
    // 24 kHz call-mode rate while BGMDevice stays at 48 kHz).
    AudioObjectID _rateListenerDevice;
    AudioObjectPropertyListenerBlock _rateBlock;
}

static AudioObjectPropertyAddress NominalSampleRateAddress(void) {
    return (AudioObjectPropertyAddress){
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
}

- (BOOL)isRunning { return _running; }

// Both instances of the BGM virtual device, so we can exclude them from the
// list of "real" output devices the user can pick.
- (BOOL)isBGMDeviceID:(AudioObjectID)deviceID {
    if (!_manager) { return NO; }
    try {
        BGMBackgroundMusicDevice bgm = [_manager bgmDevice];
        return deviceID == bgm.GetObjectID() ||
               deviceID == bgm.GetUISoundsBGMDeviceInstance().GetObjectID();
    } catch (...) {
        return NO;
    }
}

- (void)requestInputPermission:(void (^)(BOOL))completion {
    if (@available(macOS 10.14, *)) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    }
}

- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error {
    if (_running) { return YES; }

    _manager = [BGMAudioDeviceManager new];
    if (!_manager) {
        if (error) {
            *error = [NSError errorWithDomain:@"MacMixer"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey:
                @"The MacMixer audio driver isn't installed. Run the installer "
                 "(install.sh), then restart MacMixer." }];
        }
        return NO;
    }

    // Pick the device we'll actually play audio through: the system's current
    // default output, unless that's already a BGM device (e.g. left over from a
    // previous run), in which case fall back to the first real output device.
    AudioObjectID outputID = kAudioObjectUnknown;
    try {
        CAHALAudioSystemObject system;
        outputID = system.GetDefaultAudioDevice(false /*input*/, false /*system*/);
    } catch (...) {
        outputID = kAudioObjectUnknown;
    }

    if (outputID == kAudioObjectUnknown || [self isBGMDeviceID:outputID]) {
        NSArray<MixerOutputDevice *> *devices = [self availableOutputDevices];
        outputID = devices.firstObject ? devices.firstObject.deviceID : kAudioObjectUnknown;
    }

    if (outputID == kAudioObjectUnknown) {
        if (error) {
            *error = [NSError errorWithDomain:@"MacMixer"
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey:
                @"Couldn't find an audio output device." }];
        }
        _manager = nil;
        return NO;
    }

    NSError *setErr = [_manager setOutputDeviceWithID:outputID revertOnFailure:NO];
    if (setErr) { if (error) { *error = setErr; } _manager = nil; return NO; }

    NSError *defErr = [_manager setBGMDeviceAsOSDefault];
    if (defErr) { if (error) { *error = defErr; } _manager = nil; return NO; }

    // Connect to BGMXPCHelper so BGMDriver can tell us to start output IO the
    // moment an app begins playing. Without this, playthrough doesn't start
    // until the output device is changed manually.
    _xpcListener = [[BGMXPCListener alloc] initWithAudioDevices:_manager
                                  helperConnectionErrorHandler:^(NSError *err) {
        NSLog(@"MacMixer: BGMXPCHelper connection error: %@", err);
    }];

    [self installRateListenerForDevice:[self currentOutputDeviceID]];

    _running = YES;
    return YES;
}

- (void)stop {
    if (!_running || !_manager) { return; }
    [self removeRateListener];
    [_manager unsetBGMDeviceAsOSDefault];
    _xpcListener = nil;
    _running = NO;
}

// ── Output-device sample-rate listener ──────────────────────────────────────

- (void)installRateListenerForDevice:(AudioObjectID)deviceID {
    [self removeRateListener];
    if (deviceID == kAudioObjectUnknown) { return; }

    __weak MixerEngine *weakSelf = self;
    _rateBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        #pragma unused(inNumberAddresses, inAddresses)
        MixerEngine *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_running) {
            [strongSelf->_manager resyncSampleRate];
        }
    };

    AudioObjectPropertyAddress addr = NominalSampleRateAddress();
    OSStatus st = AudioObjectAddPropertyListenerBlock(deviceID, &addr,
                                                      dispatch_get_main_queue(),
                                                      _rateBlock);
    if (st == noErr) {
        _rateListenerDevice = deviceID;
    } else {
        _rateBlock = nil;
    }
}

- (void)removeRateListener {
    if (_rateListenerDevice != kAudioObjectUnknown && _rateBlock) {
        AudioObjectPropertyAddress addr = NominalSampleRateAddress();
        AudioObjectRemovePropertyListenerBlock(_rateListenerDevice, &addr,
                                               dispatch_get_main_queue(),
                                               _rateBlock);
    }
    _rateBlock = nil;
    _rateListenerDevice = kAudioObjectUnknown;
}

// ── Output devices ──────────────────────────────────────────────────────────

- (NSArray<MixerOutputDevice *> *)availableOutputDevices {
    NSMutableArray<MixerOutputDevice *> *result = [NSMutableArray array];
    try {
        CAHALAudioSystemObject system;
        UInt32 count = system.GetNumberAudioDevices();
        if (count == 0) { return result; }

        std::vector<AudioObjectID> ids(count);
        system.GetAudioDevices(count, ids.data());

        for (UInt32 i = 0; i < count; i++) {
            AudioObjectID devID = ids[i];
            if (devID == kAudioObjectUnknown || [self isBGMDeviceID:devID]) { continue; }

            try {
                CAHALAudioDevice dev(devID);
                if (dev.GetTotalNumberChannels(false /*output*/) == 0) { continue; }

                CFStringRef cfName = dev.CopyName();   // +1
                NSString *name = (__bridge_transfer NSString *)cfName ?: @"Unknown Device";
                [result addObject:[[MixerOutputDevice alloc] initWithID:devID name:name]];
            } catch (...) {
                continue;  // skip devices the HAL errors on
            }
        }
    } catch (...) { }
    return result;
}

- (AudioObjectID)currentOutputDeviceID {
    if (!_manager) { return kAudioObjectUnknown; }
    try {
        return [_manager outputDevice].GetObjectID();
    } catch (...) {
        return kAudioObjectUnknown;
    }
}

- (BOOL)setOutputDeviceID:(AudioObjectID)deviceID {
    if (!_manager) { return NO; }
    NSError *err = [_manager setOutputDeviceWithID:deviceID revertOnFailure:YES];
    if (err == nil) {
        // Move the sample-rate listener to the newly selected output device.
        [self installRateListenerForDevice:[self currentOutputDeviceID]];
    }
    return err == nil;
}

// ── Master volume ─────────────────────────────────────────────────────────────

- (BOOL)hasMasterVolume {
    if (!_manager) { return NO; }
    try {
        return [_manager bgmDevice].HasSettableMasterVolume(kScope);
    } catch (...) { return NO; }
}

- (float)masterVolume {
    if (!_manager) { return 0.0f; }
    try {
        return [_manager bgmDevice].GetVolumeControlScalarValue(kScope, kMasterChannel);
    } catch (...) { return 0.0f; }
}

- (void)setMasterVolume:(float)volume {
    if (!_manager) { return; }
    if (volume < 0.0f) { volume = 0.0f; }
    if (volume > 1.0f) { volume = 1.0f; }
    try {
        [_manager bgmDevice].SetVolumeControlScalarValue(kScope, kMasterChannel, volume);
    } catch (...) { }
}

- (BOOL)hasMasterMute {
    if (!_manager) { return NO; }
    try {
        return [_manager bgmDevice].HasSettableMasterMute(kScope);
    } catch (...) { return NO; }
}

- (BOOL)isMasterMuted {
    if (!_manager || !self.hasMasterMute) { return NO; }
    try {
        return [_manager bgmDevice].GetMuteControlValue(kScope, kMasterChannel);
    } catch (...) { return NO; }
}

- (void)setMasterMuted:(BOOL)muted {
    if (!_manager || !self.hasMasterMute) { return; }
    try {
        [_manager bgmDevice].SetMuteControlValue(kScope, kMasterChannel, muted);
    } catch (...) { }
}

// ── Per-app volume ────────────────────────────────────────────────────────────

- (void)setVolume:(int)volume forAppWithPID:(pid_t)pid bundleID:(NSString *_Nullable)bundleID {
    if (!_manager) { return; }
    if (volume < kAppRelativeVolumeMinRawValue) { volume = kAppRelativeVolumeMinRawValue; }
    if (volume > kAppRelativeVolumeMaxRawValue) { volume = kAppRelativeVolumeMaxRawValue; }
    try {
        [_manager bgmDevice].SetAppVolume(volume,
                                          pid > 0 ? pid : -1,
                                          (__bridge CFStringRef _Nullable)bundleID);
    } catch (...) { }
}

- (int)volumeForAppWithPID:(pid_t)pid bundleID:(NSString *_Nullable)bundleID {
    if (!_manager) { return kMixerNeutralRawVolume; }

    CFArrayRef appVolumes = NULL;
    try {
        appVolumes = [_manager bgmDevice].GetAppVolumes();   // +1
    } catch (...) {
        return kMixerNeutralRawVolume;
    }
    if (!appVolumes) { return kMixerNeutralRawVolume; }

    int found = kMixerNeutralRawVolume;
    CFIndex n = CFArrayGetCount(appVolumes);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(appVolumes, i);
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) { continue; }

        BOOL matches = NO;

        if (pid > 0) {
            CFNumberRef entryPID =
                (CFNumberRef)CFDictionaryGetValue(entry, CFSTR(kBGMAppVolumesKey_ProcessID));
            if (entryPID && CFGetTypeID(entryPID) == CFNumberGetTypeID()) {
                pid_t p = 0;
                CFNumberGetValue(entryPID, kCFNumberIntType, &p);
                if (p == pid) { matches = YES; }
            }
        }

        if (!matches && bundleID) {
            CFStringRef entryBID =
                (CFStringRef)CFDictionaryGetValue(entry, CFSTR(kBGMAppVolumesKey_BundleID));
            if (entryBID && CFGetTypeID(entryBID) == CFStringGetTypeID()) {
                if (CFStringCompare(entryBID, (__bridge CFStringRef)bundleID, 0) ==
                        kCFCompareEqualTo) {
                    matches = YES;
                }
            }
        }

        if (matches) {
            CFNumberRef rvol =
                (CFNumberRef)CFDictionaryGetValue(entry, CFSTR(kBGMAppVolumesKey_RelativeVolume));
            if (rvol && CFGetTypeID(rvol) == CFNumberGetTypeID()) {
                CFNumberGetValue(rvol, kCFNumberIntType, &found);
            }
            break;
        }
    }

    CFRelease(appVolumes);
    return found;
}

@end

#pragma clang assume_nonnull end
