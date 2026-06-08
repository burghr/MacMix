import AppKit
import SwiftUI

/// Owns the menu bar status item and the popover, and drives the MixerModel
/// lifecycle. Menu-bar-only (LSUIElement); no dock icon. Mirrors mac-macro's
/// AppDelegate pattern: a transient NSPopover hosting a SwiftUI view, with a
/// right-click NSMenu for permissions/quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // ── status item ─────────────────────────────────────────────────────────

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "slider.vertical.3",
                                accessibilityDescription: "MacMixer")
            btn.image?.isTemplate = true
            btn.action = #selector(statusItemClicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshAll()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // ── context menu ──────────────────────────────────────────────────────────

    private func showContextMenu() {
        let menu = NSMenu()

        let mic = NSMenuItem(title: "Microphone Permission…",
                             action: #selector(openMicrophonePrefs),
                             keyEquivalent: "")
        mic.target = self
        menu.addItem(mic)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacMixer",
                              action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        // Standard NSStatusItem context-menu pattern: assign, re-click to pop,
        // then clear so left-clicks fall through to the toggle action again.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    @objc private func openMicrophonePrefs() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // ── popover ───────────────────────────────────────────────────────────────

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopupView().environmentObject(model)
        )
    }
}
