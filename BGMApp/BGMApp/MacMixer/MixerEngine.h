// This file is part of MacMixer, a fork of Background Music.
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
//  MixerEngine.h
//  MacMixer
//
//  A thin, Swift-facing Objective-C facade over Background Music's audio core
//  (BGMAudioDeviceManager + BGMBackgroundMusicDevice). It owns the BGM virtual
//  device lifecycle, output-device selection, master volume, and per-app volume
//  — everything the SwiftUI front end needs, and nothing about the UI.
//
//  All C++ (CAHAL / BGM*) types are kept out of this header so Swift can import
//  it directly without a C++ interop layer.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// A selectable hardware output device (speakers, headphones, etc.).
@interface MixerOutputDevice : NSObject
@property (nonatomic, readonly) AudioObjectID deviceID;
@property (nonatomic, readonly, copy) NSString *name;
@end

@interface MixerEngine : NSObject

/// Brings the engine up: creates the BGM device manager, picks the current real
/// output device, makes the BGM virtual device the system default, and starts
/// playthrough. Returns NO and sets *error if the BGM driver isn't installed or
/// startup fails.
///
/// Microphone (audio input) permission must already be granted — BGM plays the
/// captured audio back through a virtual input. Call -requestInputPermission:
/// first.
- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error;

/// Restores the user's previous default output device. Call on quit.
- (void)stop;

@property (nonatomic, readonly) BOOL isRunning;

/// Requests microphone/input permission (required for playthrough on macOS
/// 10.14+). Calls completion on the main queue with the granted flag.
- (void)requestInputPermission:(void (^)(BOOL granted))completion;

// ── Output device selection ────────────────────────────────────────────────

/// Real output devices the user can route audio to (excludes the BGM device).
- (NSArray<MixerOutputDevice *> *)availableOutputDevices;

/// The device MacMixer is currently playing audio through (kAudioObjectUnknown
/// if none).
- (AudioObjectID)currentOutputDeviceID;

/// Routes audio to the given device. Returns NO on failure.
- (BOOL)setOutputDeviceID:(AudioObjectID)deviceID;

// ── Master volume ───────────────────────────────────────────────────────────

@property (nonatomic, readonly) BOOL hasMasterVolume;
- (float)masterVolume;            // 0.0 ... 1.0
- (void)setMasterVolume:(float)volume;

@property (nonatomic, readonly) BOOL hasMasterMute;
- (BOOL)isMasterMuted;
- (void)setMasterMuted:(BOOL)muted;

// ── Per-app volume ────────────────────────────────────────────────────────────

/// Current relative volume for an app, 0...100 (defaults to 100 if never set).
- (int)volumeForAppWithPID:(pid_t)pid bundleID:(NSString *_Nullable)bundleID
    NS_SWIFT_NAME(volume(pid:bundleID:));

/// Sets an app's relative volume. @c volume is clamped to 0...100.
- (void)setVolume:(int)volume forAppWithPID:(pid_t)pid bundleID:(NSString *_Nullable)bundleID
    NS_SWIFT_NAME(setVolume(_:pid:bundleID:));

@end

NS_ASSUME_NONNULL_END
