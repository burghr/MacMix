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

import SwiftUI
import AppKit
import Combine
import CoreAudio

/// Observable bridge between the SwiftUI UI and the ObjC++ MixerEngine.
/// Owns the engine lifecycle and publishes the state the popover renders:
/// output devices, master volume, and per-app sliders.
@MainActor
final class MixerModel: ObservableObject {
    /// One running app with an audio slider.
    struct AppEntry: Identifiable {
        let id: pid_t            // process identifier
        let name: String
        let bundleID: String?
        let icon: NSImage?
        var volume: Double       // 0...100
    }

    @Published var running: Bool = false
    @Published var startupError: String? = nil

    @Published var outputDevices: [MixerOutputDevice] = []
    @Published var currentOutputID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    @Published var hasMaster: Bool = false
    @Published var masterVolume: Double = 0      // 0...1
    @Published var hasMute: Bool = false
    @Published var muted: Bool = false

    @Published var apps: [AppEntry] = []

    /// Whether the popover is currently revealing user-hidden apps.
    @Published var showingHidden = false

    /// Stable keys (bundle id, or name as a fallback) of apps the user hid.
    @Published private var hiddenKeys: Set<String> = []
    private static let hiddenDefaultsKey = "userHiddenAppKeys"
    private static let didSeedDefaultsKey = "didSeedDefaultHiddenApps"

    /// Utility apps that don't play audio — hidden by default on first run.
    private static let defaultHiddenKeys: Set<String> = [
        "com.apple.finder",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.systempreferences",   // System Settings
        "com.apple.ActivityMonitor",
    ]

    private let engine = MixerEngine()
    private var refreshTimer: Timer?

    // Apps we never want to show a slider for (ourselves + the helper).
    private let hiddenBundleIDs: Set<String> = [
        "com.bearisdriving.BGM.App",          // this app's bundle id (kept from BGM)
        Bundle.main.bundleIdentifier ?? ""
    ]

    init() {
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDefaultsKey) ?? [])

        // Seed default-hidden utilities once, merging into (not replacing) the
        // user's set, so existing installs get them too and unhiding one sticks.
        if !UserDefaults.standard.bool(forKey: Self.didSeedDefaultsKey) {
            hiddenKeys.formUnion(Self.defaultHiddenKeys)
            UserDefaults.standard.set(true, forKey: Self.didSeedDefaultsKey)
            persistHidden()
        }
    }

    // ── Hiding apps ───────────────────────────────────────────────────────────

    /// Apps the user hasn't hidden (the normal list).
    var visibleApps: [AppEntry] { apps.filter { !hiddenKeys.contains(Self.hideKey(for: $0)) } }
    /// Currently-running apps the user has hidden (shown under "Show hidden").
    var hiddenApps:  [AppEntry] { apps.filter {  hiddenKeys.contains(Self.hideKey(for: $0)) } }

    static func hideKey(for entry: AppEntry) -> String { entry.bundleID ?? entry.name }

    func hide(_ entry: AppEntry) {
        hiddenKeys.insert(Self.hideKey(for: entry))
        persistHidden()
    }

    func unhide(_ entry: AppEntry) {
        hiddenKeys.remove(Self.hideKey(for: entry))
        persistHidden()
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenKeys), forKey: Self.hiddenDefaultsKey)
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    func start() {
        engine.requestInputPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.startupError = "MacMixer needs microphone permission. It uses a virtual "
                    + "input device to route each app's audio. Grant it in System Settings → "
                    + "Privacy & Security → Microphone, then relaunch."
                return
            }
            do {
                try self.engine.start()
                self.running = true
                self.refreshAll()
                self.startPolling()
            } catch {
                self.startupError = error.localizedDescription
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine.stop()
        running = false
    }

    /// Re-read everything. Cheap enough to call when the popover opens.
    func refreshAll() {
        refreshDevices()
        refreshMaster()
        refreshApps()
    }

    private func startPolling() {
        refreshTimer?.invalidate()
        // Light background refresh so external changes (volume keys, apps
        // launching/quitting) show up while the popover is open.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    // ── Output devices ────────────────────────────────────────────────────────

    func refreshDevices() {
        outputDevices = engine.availableOutputDevices()
        currentOutputID = engine.currentOutputDeviceID()
    }

    func selectOutput(_ deviceID: AudioObjectID) {
        guard engine.setOutputDeviceID(deviceID) else { return }
        currentOutputID = engine.currentOutputDeviceID()
    }

    // ── Master ──────────────────────────────────────────────────────────────────

    func refreshMaster() {
        hasMaster = engine.hasMasterVolume
        if hasMaster { masterVolume = Double(engine.masterVolume()) }
        hasMute = engine.hasMasterMute
        if hasMute { muted = engine.isMasterMuted() }
    }

    func setMaster(_ value: Double) {
        masterVolume = value
        engine.setMasterVolume(Float(value))
    }

    func toggleMute() {
        muted.toggle()
        engine.setMasterMuted(muted)
    }

    // ── Per-app volumes ─────────────────────────────────────────────────────────

    func refreshApps() {
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !(($0.bundleIdentifier).map(hiddenBundleIDs.contains) ?? false)
        }

        // Reuse existing entries by PID so we don't re-fetch icons or churn
        // structs every tick. The on-screen slider is the source of truth for
        // volume; the engine is only queried for apps we're seeing for the
        // first time.
        let existing = Dictionary(apps.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })

        var updated: [AppEntry] = []
        updated.reserveCapacity(regular.count)
        for app in regular {
            let pid = app.processIdentifier
            if let entry = existing[pid] {
                updated.append(entry)
            } else {
                let bid = app.bundleIdentifier
                updated.append(AppEntry(
                    id: pid,
                    name: app.localizedName ?? bid ?? "App \(pid)",
                    bundleID: bid,
                    icon: app.icon,
                    volume: Self.rawToPercent(engine.volume(pid: pid, bundleID: bid))
                ))
            }
        }
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Only republish when the set of apps actually changed. Reassigning the
        // whole @Published array on every tick races SwiftUI's ForEach diffing
        // (it copies AppEntry mid-render) and can crash on a stale reference.
        if updated.map(\.id) != apps.map(\.id) {
            apps = updated
        }
    }

    func setVolume(_ value: Double, for entry: AppEntry) {
        if let idx = apps.firstIndex(where: { $0.id == entry.id }) {
            apps[idx].volume = value
        }
        engine.setVolume(Self.percentToRaw(value), pid: entry.id, bundleID: entry.bundleID)
    }

    // BGM's per-app scale is raw 0...100 with unity gain (normal volume) at the
    // midpoint (50); above that boosts up to ~4x. We present a 0...200% mixer
    // where 100% == the app's normal volume (raw 50), 0% == mute, and >100% is
    // boost. So raw = percent / 2 and percent = raw * 2.
    static let normalPercent: Double = 100
    static let maxPercent: Double = 200

    private static func percentToRaw(_ percent: Double) -> Int32 {
        Int32((percent / 2.0).rounded())
    }

    private static func rawToPercent(_ raw: Int32) -> Double {
        min(maxPercent, Double(raw) * 2.0)
    }
}
