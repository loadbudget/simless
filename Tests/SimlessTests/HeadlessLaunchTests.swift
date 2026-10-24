// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Every app simless launches gets SimlessRuntime and SIMLESS_HEADLESS, so the
/// runtime hides it whether or not the app has SimlessKit.
final class HeadlessLaunchTests: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-headless-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try """
            {"project": "App.xcodeproj", "scheme": "App", "appTarget": "App", "testTarget": "AppTests", "sourceDirs": ["Src"], "device": "iphone"}
            """.write(toFile: "\(root!)/.simless.json", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: root))
    }

    /// A slot with its runtime copy in place, as `simless up` leaves it.
    func slot(kind: String?, builtWithKit: Bool) throws -> SlotRecord {
        let s = SlotRecord(bundleBase: "com.example.app", n: 1, worktree: root, port: 50000, kind: kind, builtWithKit: builtWithKit)
        try FileManager.default.createDirectory(atPath: s.dir, withIntermediateDirectories: true)
        try "dylib".write(toFile: "\(s.dir)/SimlessRuntime.dylib", atomically: true, encoding: .utf8)
        return s
    }

    func assertHidden(_ env: [String: String], _ s: SlotRecord, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(env["SIMLESS_HEADLESS"], "1", file: file, line: line)
        XCTAssertEqual(env["DYLD_INSERT_LIBRARIES"], "\(s.dir)/SimlessRuntime.dylib", file: file, line: line)
    }

    func testATestHostGetsTheRuntimeAndHeadlessWithAndWithoutTheKit() throws {
        for kit in [false, true] {
            let s = try slot(kind: "test", builtWithKit: kit)
            let env = RuntimeHost.testEnvironment(s, extra: ["SIMLESS_IDLE": "600"])
            assertHidden(env, s)
            XCTAssertEqual(env["SIMLESS_RUNTIME_PORT"], "50000")
            XCTAssertEqual(env["SIMLESS_IDLE"], "600")
        }
    }

    func testARenderHostGetsTheRuntimeAndHeadlessOnBothLaunchPaths() throws {
        for kit in [false, true] {
            let s = try slot(kind: nil, builtWithKit: kit)
            assertHidden(Native.spawnEnvironment(s, extra: RuntimeHost.renderEnvironment(s)), s)
            let open = Slots.openCommand(s, app: "/A.app", idleMinutes: 30, extra: [])
            XCTAssertTrue(open.contains("SIMLESS_HEADLESS=1"))
            XCTAssertTrue(open.contains("DYLD_INSERT_LIBRARIES=\(s.dir)/SimlessRuntime.dylib"))
        }
    }

    // MARK: - The install run's .xctestrun

    let runtime = "/slots/s/SimlessRuntime.dylib"

    func target(host: String) -> [String: Any] {
        ["TestHostBundleIdentifier": host,
         "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/usr/lib/libRPAC.dylib", "TERM": "dumb"],
         "TestingEnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib",
                                         "XCInjectBundleInto": "unused"]]
    }

    func retarget(_ plist: [String: Any]) throws -> [String: Any] {
        let src = "\(root!)/in.xctestrun", dst = "\(root!)/out.xctestrun"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: src))
        try Slots.retargetXCTestRun(from: src, to: dst, hostBundleID: "com.example.app", slotID: "com.example.app.simless1", runtime: runtime)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: dst))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The app it hosts gets the runtime after xcodebuild's own libraries; the
    /// rest of each target stays as the build wrote it.
    func assertAppHosted(_ t: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t?["TestHostBundleIdentifier"] as? String, "com.example.app.simless1", file: file, line: line)
        let testing = t?["TestingEnvironmentVariables"] as? [String: Any]
        XCTAssertEqual(testing?["DYLD_INSERT_LIBRARIES"] as? String,
                       "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib:\(runtime)", file: file, line: line)
        XCTAssertEqual(testing?["XCInjectBundleInto"] as? String, "unused", file: file, line: line)
        let env = t?["EnvironmentVariables"] as? [String: Any]
        XCTAssertEqual(env?["SIMLESS_HEADLESS"] as? String, "1", file: file, line: line)
        XCTAssertEqual(env?["DYLD_INSERT_LIBRARIES"] as? String, "/usr/lib/libRPAC.dylib", file: file, line: line)
        XCTAssertEqual(env?["TERM"] as? String, "dumb", file: file, line: line)
    }

    /// A UI test target runs in its own runner app: no runtime goes into it.
    func assertRunnerUntouched(_ t: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t?["TestHostBundleIdentifier"] as? String, "com.example.app.uitests.xctrunner", file: file, line: line)
        let testing = t?["TestingEnvironmentVariables"] as? [String: Any]
        XCTAssertEqual(testing?["DYLD_INSERT_LIBRARIES"] as? String,
                       "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib", file: file, line: line)
    }

    func testTheV1FormatInsertsTheRuntimeIntoTheAppHostedTarget() throws {
        let out = try retarget(["__xctestrun_metadata__": ["FormatVersion": 1],
                                "AppTests": target(host: "com.example.app"),
                                "AppUITests": target(host: "com.example.app.uitests.xctrunner")])
        assertAppHosted(out["AppTests"] as? [String: Any])
        assertRunnerUntouched(out["AppUITests"] as? [String: Any])
        XCTAssertEqual((out["__xctestrun_metadata__"] as? [String: Any])?["FormatVersion"] as? Int, 1)
    }

    func testTheV2FormatInsertsTheRuntimeIntoTheAppHostedTarget() throws {
        let out = try retarget(["__xctestrun_metadata__": ["FormatVersion": 2],
                                "TestConfigurations": [["Name": "Default",
                                                        "TestTargets": [target(host: "com.example.app"),
                                                                        target(host: "com.example.app.uitests.xctrunner")]]]])
        let targets = try XCTUnwrap((out["TestConfigurations"] as? [[String: Any]])?.first?["TestTargets"] as? [[String: Any]])
        assertAppHosted(targets[0])
        assertRunnerUntouched(targets[1])
    }

    /// A target with no inserted libraries of its own gets the runtime alone,
    /// and a second pass over the output adds it once.
    func testTheRuntimeIsInsertedOnceIntoATargetWithNoInsertedLibraries() throws {
        var bare = target(host: "com.example.app")
        bare["TestingEnvironmentVariables"] = nil
        let once = try retarget(["AppTests": bare])
        XCTAssertEqual(((once["AppTests"] as? [String: Any])?["TestingEnvironmentVariables"] as? [String: Any])?["DYLD_INSERT_LIBRARIES"] as? String, runtime)
        var again = try XCTUnwrap(once["AppTests"] as? [String: Any])
        again["TestHostBundleIdentifier"] = "com.example.app"
        let twice = try retarget(["AppTests": again])
        XCTAssertEqual(((twice["AppTests"] as? [String: Any])?["TestingEnvironmentVariables"] as? [String: Any])?["DYLD_INSERT_LIBRARIES"] as? String, runtime)
    }
}
