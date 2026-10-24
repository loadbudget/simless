// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// SimlessRuntime makes `UIDevice.current.userInterfaceIdiom` report phone
/// while a window has a root that overrode the idiom to phone when it was
/// set, as a render under `--idiom phone` does. Slow: it builds the runtime
/// and a Mac Catalyst app, so it runs only with SIMLESS_SLOW_TESTS=1.
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

    /// The device's idiom after each step, by name: "phone", or "mac" for the
    /// Mac's own. A step that throws (UIKit's "Cannot override interface idiom")
    /// ends the probe without its line.
    func testTheDeviceIdiomFollowsAPhoneRoot() throws {
        let seen = try runProbe()
        XCTAssertEqual(seen, [
            "start=mac",
            "phoneRoot=phone",
            "otherWindowRoot=phone",
            "otherWindowVisible=phone",
            "alert=phone",
            "nilRoot=mac",
            "releasedWindow=mac",
            "twoPhoneWindows=phone",
            "oneLeft=phone",
            "noneLeft=mac",
        ])
    }

    func runProbe() throws -> [String] {
        let runtime = try RuntimeBuild.nativeDylib()
        try """
            import UIKit

            final class Probe: NSObject, UIApplicationDelegate {
                var steps: [String] = []

                func step(_ name: String) {
                    steps.append(name + "=" + (UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "mac"))
                }

                func phoneRoot() -> UIViewController {
                    let vc = UIViewController()
                    vc.traitOverrides.userInterfaceIdiom = .phone
                    return vc
                }

                func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
                    let window = UIWindow(frame: frame), other = UIWindow(frame: frame)
                    step("start")
                    let root = phoneRoot()
                    window.rootViewController = root
                    window.isHidden = false
                    step("phoneRoot")
                    other.rootViewController = UIViewController()
                    step("otherWindowRoot")
                    other.isHidden = false
                    step("otherWindowVisible")
                    let alert = UIAlertController(title: "Probe", message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    root.present(alert, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        step("alert")
                        root.dismiss(animated: false)
                        window.rootViewController = nil
                        step("nilRoot")
                        autoreleasepool {
                            let released = UIWindow(frame: frame)
                            released.rootViewController = phoneRoot()
                        }
                        step("releasedWindow")
                        window.rootViewController = phoneRoot()
                        other.rootViewController = phoneRoot()
                        step("twoPhoneWindows")
                        other.rootViewController = UIViewController()
                        step("oneLeft")
                        window.rootViewController = UIViewController()
                        step("noneLeft")
                        print("idioms " + steps.joined(separator: " "))
                        fflush(stdout)
                        exit(0)
                    }
                    return true
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
        let env = ProcessInfo.processInfo.environment.merging([
            "DYLD_INSERT_LIBRARIES": runtime, "SIMLESS_HEADLESS": "1", "SIMLESS_NATIVE": "1",
            "SIMLESS_UI": "", "SIMLESS_INSTALL_REPORT": "", "CFFIXED_USER_HOME": home, "HOME": home,
        ]) { $1 }
        // A probe that never finishes launching is stopped after 60 s (exit code 15).
        let deadline = Date().addingTimeInterval(60)
        let r = try Shell.stream([probe], logPath: "\(dir!)/probe.log", env: env, onLine: { _ in }, tick: { Date() < deadline })
        XCTAssertEqual(r.code, 0, r.out)
        let line = r.out.split(separator: "\n").first { $0.hasPrefix("idioms ") } ?? ""
        return line.split(separator: " ").dropFirst().map(String.init)
    }
}
