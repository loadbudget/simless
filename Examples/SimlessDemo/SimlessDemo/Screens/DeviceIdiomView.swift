// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI
import UIKit

/// The idioms a screen can branch on: the device's, which many apps read for
/// layout, and the trait collection's. Under `--idiom phone` both say phone.
struct DeviceIdiomView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 12) {
            Text("device idiom \(Self.name(UIDevice.current.userInterfaceIdiom))")
            Text("device model \(UIDevice.current.model)")
            Text(sizeClass == .compact ? "compact width" : "regular width")
        }
    }

    static func name(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: "phone"
        case .pad: "pad"
        case .mac: "mac"
        default: "other"
        }
    }
}

#Preview("Idiom") {
    DeviceIdiomView()
}
