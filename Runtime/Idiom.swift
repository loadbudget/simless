// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import ObjectiveC
import os
import UIKit

/// The idiom on the Mac. An iOS app there takes it from the screen, and simless
/// asks for the phone idiom on a render's hosting controller only (SimlessKit),
/// so two things break that a device never sees:
/// - A window with no scene (the render window on a Mac with no login session)
///   has the screen's idiom, and on
///   some Macs the screen reports none: then every List traps in UIKit
///   ("unknown user interface idiom (UIUserInterfaceIdiom(rawValue: -1))").
///   Windows in render and unit test hosts get the device's idiom outright.
/// - SwiftUI hands a NavigationStack inside a sheet the screen's traits as an
///   override, iPad idiom included, under a phone-idiom parent, and UIKit
///   throws ("Cannot override interface idiom to UIUserInterfaceIdiomPad when
///   original interface idiom is UIUserInterfaceIdiomPhone"). A child keeps its
///   parent's idiom instead.
///
/// `UIDevice.current.userInterfaceIdiom` follows the render: it reports phone
/// while some window's root overrode the idiom to phone when it was set
/// (SimlessKit and the render server set it first for `--idiom phone`), so
/// code that branches on the device takes the iPhone branch too. Another root
/// in that window (the next render), or the window's release, takes it out;
/// with no such window left, the Mac's idiom is back. Overrides changed after
/// the root is set aren't followed.
enum Idiom {
    /// Windows whose root asked for the phone idiom, held weakly; read from any thread.
    private static let phoneWindows = OSAllocatedUnfairLock(uncheckedState: NSHashTable<UIWindow>.weakObjects())

    static func install(windows: Bool) {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        keepParentIdiom()
        guard windows else { return }
        let mac = UIDevice.current.userInterfaceIdiom
        let idiom: UIUserInterfaceIdiom = mac == .unspecified ? .pad : mac
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? UIWindow, !w.traitOverrides.contains(UITraitUserInterfaceIdiom.self) else { return }
                w.traitOverrides.userInterfaceIdiom = idiom
            }
        }
        reportDevice()
        followRootViewController()
    }

    private static func reportDevice() {
        let sel = NSSelectorFromString("userInterfaceIdiom")
        guard let m = class_getInstanceMethod(UIDevice.self, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int
        let original = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject) -> Int = { d in
            phoneWindows.withLockUnchecked { $0.anyObject != nil } ? UIUserInterfaceIdiom.phone.rawValue : original(d, sel)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Set before UIKit installs the root, so its first layout already reads phone.
    private static func followRootViewController() {
        let sel = NSSelectorFromString("setRootViewController:")
        guard let m = class_getInstanceMethod(UIWindow.self, sel) else { return }
        typealias Fn = @convention(c) (UIWindow, Selector, UIViewController?) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (UIWindow, UIViewController?) -> Void = { window, root in
            // Off the main thread UIKit itself complains; the idiom isn't followed there.
            guard Thread.isMainThread else { return original(window, sel, root) }
            let phone = MainActor.assumeIsolated { phone(root) }
            phoneWindows.withLockUnchecked { phone ? $0.add(window) : $0.remove(window) }
            original(window, sel, root)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    @MainActor private static func phone(_ root: UIViewController?) -> Bool {
        guard let o = root?.traitOverrides, o.contains(UITraitUserInterfaceIdiom.self) else { return false }
        return o.userInterfaceIdiom == .phone
    }

    private static func keepParentIdiom() {
        let sel = NSSelectorFromString("setOverrideTraitCollection:forChildViewController:")
        guard let m = class_getInstanceMethod(UIViewController.self, sel) else { return }
        typealias Fn = @convention(c) (UIViewController, Selector, UITraitCollection?, UIViewController) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (UIViewController, UITraitCollection?, UIViewController) -> Void = { parent, traits, child in
            var traits = traits
            let wanted = traits?.userInterfaceIdiom ?? .unspecified, own = parent.traitCollection.userInterfaceIdiom
            if wanted != .unspecified, own != .unspecified, wanted != own {
                traits = traits?.modifyingTraits { $0.userInterfaceIdiom = own }
            }
            original(parent, sel, traits, child)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
