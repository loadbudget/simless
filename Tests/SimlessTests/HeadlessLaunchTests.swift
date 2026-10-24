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

    func testATestHostGetsTheRuntimeAndHeadless() throws {
        let s = try slot(kind: "test", builtWithKit: false)
        let env = RuntimeHost.testEnvironment(s, extra: ["SIMLESS_IDLE": "600"])
        assertHidden(env, s)
        XCTAssertEqual(env["SIMLESS_RUNTIME_PORT"], "50000")
        XCTAssertEqual(env["SIMLESS_IDLE"], "600")
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

    func retarget(_ plist: [String: Any], reportPort: Int? = nil) throws -> [String: Any] {
        let src = "\(root!)/in.xctestrun", dst = "\(root!)/out.xctestrun"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: src))
        try Slots.retargetXCTestRun(from: src, to: dst, hostBundleID: "com.example.app", slotID: "com.example.app.simless1",
                                    runtime: runtime, reportPort: reportPort)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: dst))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The app it hosts gets the runtime after xcodebuild's own libraries; the
    /// rest of each target stays as the build wrote it.
    func assertAppHosted(_ t: [String: Any]?, environment: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t?["TestHostBundleIdentifier"] as? String, "com.example.app.simless1", file: file, line: line)
        let testing = t?["TestingEnvironmentVariables"] as? [String: Any]
        XCTAssertEqual(testing?["DYLD_INSERT_LIBRARIES"] as? String,
                       "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib:/usr/lib/libRPAC.dylib:\(runtime)", file: file, line: line)
        XCTAssertEqual(testing?["XCInjectBundleInto"] as? String, "unused", file: file, line: line)
        let env = t?["EnvironmentVariables"] as? [String: Any]
        XCTAssertEqual(env?["SIMLESS_HEADLESS"] as? String, "1", file: file, line: line)
        guard environment else { return }
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

    func testing(_ plist: [String: Any]) -> [String: Any]? {
        (plist["AppTests"] as? [String: Any])?["TestingEnvironmentVariables"] as? [String: Any]
    }

    /// A target with no inserted libraries of its own gets the runtime alone,
    /// and a second pass over the output adds it once.
    func testTheRuntimeIsInsertedOnceIntoATargetWithNoInsertedLibraries() throws {
        var bare = target(host: "com.example.app")
        bare["TestingEnvironmentVariables"] = nil
        let once = try retarget(["AppTests": bare])
        XCTAssertEqual(testing(once)?["DYLD_INSERT_LIBRARIES"] as? String, runtime)
        let twice = try retarget(once)
        XCTAssertEqual(testing(twice)?["DYLD_INSERT_LIBRARIES"] as? String, runtime)
    }

    /// `install` edits the slot's file again: one that an older simless wrote
    /// (host already the slot's, no runtime) gets the runtime and the port the
    /// runtime reports on, and the next install's port replaces it.
    func testAnInstallBringsAnOlderSlotFileUpToDate() throws {
        var old = target(host: "com.example.app.simless1")
        old["EnvironmentVariables"] = ["SIMLESS_HEADLESS": "1"]
        let first = try retarget(["AppTests": old], reportPort: 60001)
        assertAppHosted(first["AppTests"] as? [String: Any], environment: false)
        XCTAssertEqual(testing(first)?["SIMLESS_INSTALL_REPORT"] as? String, "60001")
        let second = try retarget(first, reportPort: 60002)
        assertAppHosted(second["AppTests"] as? [String: Any], environment: false)
        XCTAssertEqual(testing(second)?["SIMLESS_INSTALL_REPORT"] as? String, "60002")
        XCTAssertNil(testing(try retarget(second))?["SIMLESS_INSTALL_REPORT"])
    }

    // MARK: - The install run's report

    func testAnInstallWithoutTheKitFailsWhenTheRuntimeDidNotReport() throws {
        let error = try XCTUnwrap(Slots.installHidingError(slotID: "s", kitInBuild: false, reported: false, xctestrun: "/x/slot.xctestrun", log: "/x/install.log"))
        XCTAssertTrue(error.contains("TestingEnvironmentVariables of /x/slot.xctestrun"), error)
        XCTAssertTrue(error.contains("/x/install.log"), error)
        XCTAssertNil(Slots.installHidingError(slotID: "s", kitInBuild: false, reported: true, xctestrun: "", log: ""))
    }

    /// With the kit, the kit hides the app, as before the runtime was inserted.
    func testAnInstallWithTheKitPassesWithOrWithoutTheReport() {
        XCTAssertNil(Slots.installHidingError(slotID: "s", kitInBuild: true, reported: false, xctestrun: "", log: ""))
        XCTAssertNil(Slots.installHidingError(slotID: "s", kitInBuild: true, reported: true, xctestrun: "", log: ""))
    }

    func connectAndSend(_ text: String?, port: Int) throws {
        let client = try LineClient(port: port)
        if let text { _ = text.withCString { write(client.fd, $0, strlen($0)) } }
        // The client closes its socket as it goes out of scope.
    }

    func testTheReportSocketReadsAHeadlessReportSentBeforeTheCheck() throws {
        let report = try reportSocket()
        defer { close(report.fd) }
        XCTAssertFalse(receivedReport(report.fd))
        try connectAndSend(nil, port: report.port)
        try connectAndSend("something else\n", port: report.port)
        try connectAndSend("headless\n", port: report.port)
        XCTAssertTrue(receivedReport(report.fd))
    }
}
