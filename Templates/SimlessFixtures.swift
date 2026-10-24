// SPDX-License-Identifier: MIT-0
// Copyright 2026 Abacus.AI, Inc. MIT No Attribution: you may use, copy, modify
// and distribute this file without restriction or attribution. Provided "as is",
// without warranty of any kind.

// Fixtures for `simless render`: each one builds a screen in a deterministic state.
// Copy it to <App>/Simless/ (or the folder `kitDir` in .simless.json names). It is optional.
// This file is yours; edit it freely. simless compiles it into the code it loads
// into the render host. When the app has no SimlessKit.swift, the app build leaves it out.
//
// Hot reload recompiles this file together with the edited view files, so
// fixtures always render the latest code. Keep it to view construction:
// seed data, environment objects, fixed dates, no network.
#if SIMLESS
import SwiftUI

@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    // r.add("Settings") { SettingsView() }
    // r.add("Paywall.trialEnded") { PaywallView(state: .trialEnded).environmentObject(Store.preview) }
}
#endif
