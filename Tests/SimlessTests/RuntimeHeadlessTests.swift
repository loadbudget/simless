// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// SimlessRuntime, loaded into a process, hides it on SIMLESS_HEADLESS or
/// SIMLESS_UI, and reports to the install run's socket. Slow: it builds the
/// runtime (minutes when its cache is cold) and a Mac Catalyst probe, so it runs
/// only with SIMLESS_SLOW_TESTS=1.
final class RuntimeHeadlessTests: XCTestCase {
    var dir: String!
    var probe: String!
    var runtime: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMLESS_SLOW_TESTS"] == "1", "set SIMLESS_SLOW_TESTS=1 to build and load SimlessRuntime")
        dir = NSTemporaryDirectory() + "simless-runtime-headless-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        runtime = try RuntimeBuild.nativeDylib()
        // A process of the platform the native runtime is tagged for, which
        // lives half a second: long enough for the runtime's constructor.
        try """
            import Foundation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            dispatchMain()
            """.write(toFile: "\(dir!)/main.swift", atomically: true, encoding: .utf8)
        probe = "\(dir!)/probe"
        try Shell.check(["xcrun", "swiftc", "-target", "arm64-apple-ios17.0-macabi", "\(dir!)/main.swift", "-o", probe], what: "build the probe")
        try Native.signAdHoc([probe])
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// The probe's output with the runtime inserted and `env` set.
    func runProbe(_ env: [String: String]) throws -> String {
        let base = ["DYLD_INSERT_LIBRARIES": runtime!, "SIMLESS_HEADLESS": "", "SIMLESS_UI": "", "SIMLESS_INSTALL_REPORT": ""]
        let r = try Shell.run([probe], env: base.merging(env) { $1 })
        XCTAssertEqual(r.code, 0, r.out)
        return r.out
    }

    func testTheRuntimeHidesAHeadlessHost() throws {
        XCTAssertTrue(try runProbe(["SIMLESS_HEADLESS": "1"]).contains("simless-runtime: headless"))
    }

    func testTheRuntimeHidesAUITestHost() throws {
        XCTAssertTrue(try runProbe(["SIMLESS_UI": "1"]).contains("simless-runtime: headless"))
    }

    func testTheRuntimeLeavesAnotherProcessAlone() throws {
        XCTAssertFalse(try runProbe([:]).contains("simless-runtime: headless"))
    }

    func testTheRuntimeReportsToTheInstallRun() throws {
        let report = try reportSocket()
        defer { close(report.fd) }
        _ = try runProbe(["SIMLESS_HEADLESS": "1", "SIMLESS_INSTALL_REPORT": String(report.port)])
        XCTAssertTrue(receivedReport(report.fd))
    }

    func testTheRuntimeReportsNothingWhenItDoesNotHide() throws {
        let report = try reportSocket()
        defer { close(report.fd) }
        _ = try runProbe(["SIMLESS_INSTALL_REPORT": String(report.port)])
        XCTAssertFalse(receivedReport(report.fd))
    }
}
