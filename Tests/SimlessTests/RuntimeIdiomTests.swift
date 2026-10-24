// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// SimlessRuntime makes `UIDevice.current.userInterfaceIdiom` report phone
/// while a window's root view controller overrides the idiom to phone, as a
/// render under `--idiom phone` does. Slow: it builds the runtime and a Mac
/// Catalyst app, so it runs only with SIMLESS_SLOW_TESTS=1.
final class RuntimeIdiomTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMLESS_SLOW_TESTS"] == "1", "set SIMLESS_SLOW_TESTS=1 to build and load SimlessRuntime")
        dir = NSTemporaryDirectory() + "simless-runtime-idiom-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(dir!)/Probe.app/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(dir!)/home", withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// The device's idiom (raw values) before any root, with a phone root, after
    /// another window takes a root, and after the phone root's window takes another.
    func testTheDeviceIdiomFollowsAPhoneRoot() throws {
        let seen = try runProbe(), phone = 0  // UIUserInterfaceIdiom.phone
        XCTAssertEqual(seen.count, 4, "\(seen)")
        XCTAssertNotEqual(seen.first, phone)
        XCTAssertEqual(Array(seen.dropFirst().prefix(2)), [phone, phone])
        XCTAssertEqual(seen.last, seen.first)
    }

    func runProbe() throws -> [Int] {
        let runtime = try RuntimeBuild.nativeDylib()
        try """
            import UIKit

            final class Probe: NSObject, UIApplicationDelegate {
                func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                    let other = UIWindow(frame: window.frame)
                    let phone = UIViewController()
                    phone.traitOverrides.userInterfaceIdiom = .phone
                    var seen = [UIDevice.current.userInterfaceIdiom.rawValue]
                    window.rootViewController = phone
                    seen.append(UIDevice.current.userInterfaceIdiom.rawValue)
                    other.rootViewController = UIViewController()
                    seen.append(UIDevice.current.userInterfaceIdiom.rawValue)
                    window.rootViewController = UIViewController()
                    seen.append(UIDevice.current.userInterfaceIdiom.rawValue)
                    print("idioms " + seen.map(String.init).joined(separator: " "))
                    fflush(stdout)
                    exit(0)
                }
            }

            UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Probe.self))
            """.write(toFile: "\(dir!)/main.swift", atomically: true, encoding: .utf8)
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.example.simless-idiom-probe</string>
            <key>CFBundleExecutable</key><string>probe</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>UIDeviceFamily</key><array><integer>2</integer><integer>6</integer></array>
            </dict></plist>
            """.write(toFile: "\(dir!)/Probe.app/Contents/Info.plist", atomically: true, encoding: .utf8)
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = "\(dir!)/Probe.app/Contents/MacOS/probe"
        try Shell.check(["xcrun", "swiftc", "-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                         "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                         "-I", "\(sdk)/System/iOSSupport/usr/include", "-L", "\(sdk)/System/iOSSupport/usr/lib",
                         "\(dir!)/main.swift", "-o", probe], what: "build the probe")
        try Native.signAdHoc(["\(dir!)/Probe.app"])
        // A native host, which reports itself as an iOS app on the Mac, with its home here.
        let home = "\(dir!)/home"
        let r = try Shell.run([probe], env: ["DYLD_INSERT_LIBRARIES": runtime, "SIMLESS_HEADLESS": "1", "SIMLESS_NATIVE": "1",
                                             "SIMLESS_UI": "", "SIMLESS_INSTALL_REPORT": "", "CFFIXED_USER_HOME": home, "HOME": home])
        XCTAssertEqual(r.code, 0, r.out)
        let line = r.out.split(separator: "\n").first { $0.hasPrefix("idioms ") } ?? ""
        return line.split(separator: " ").dropFirst().compactMap { Int($0) }
    }
}
