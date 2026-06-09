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

@main
struct MacMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar status item + popover are managed by AppDelegate.
        // This empty Settings scene satisfies the App protocol without showing
        // a window.
        Settings { EmptyView() }
    }
}
