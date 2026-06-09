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

/// SwiftUI wrapper around NSVisualEffectView, for real macOS blur. Mirrors the
/// mac-macro look. (NSPopover is already vibrant, but this is here for any
/// detached windows and to keep parity with mac-macro.)
struct VibrancyView: NSViewRepresentable {
    var material: NSVisualEffectView.Material         = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State               = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material      = material
        v.blendingMode  = blendingMode
        v.state         = state
        v.isEmphasized  = true
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material     = material
        view.blendingMode = blendingMode
        view.state        = state
    }
}
