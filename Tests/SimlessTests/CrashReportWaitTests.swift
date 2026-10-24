// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// How long `CrashReport.summary` looks for macOS's crash report, and what
/// answers when the report is late or never comes.
final class CrashReportWaitTests: XCTestCase {
    var root: String!
    var reports: String!
    var slot: SlotRecord!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-crash-" + UUID().uuidString
        reports = "\(root!)/DiagnosticReports"
        try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
        slot = SlotRecord(bundleBase: "com.example.app", n: 1, worktree: root, port: 50000)
        try FileManager.default.createDirectory(atPath: slot.dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: root))
    }

    /// A report as macOS writes it: a JSON header line, then the JSON body.
    func writeReport(for bundleID: String) throws {
        try """
            {"bundleID": "\(bundleID)"}
            {"exception": {"type": "EXC_BAD_ACCESS"}}
            """.write(toFile: "\(reports!)/App-\(UUID().uuidString).ips", atomically: true, encoding: .utf8)
    }

    func summary(since: Date, wait: Double, lateWait: Double) -> (String?, Double) {
        let start = now()
        let text = CrashReport.summary(slot: slot, since: since, wait: wait, lateWait: lateWait, dir: reports)
        return (text, now() - start)
    }

    func testAReportInTheFirstWaitIsRead() throws {
        let since = Date()
        try writeReport(for: slot.slotID)
        let (text, took) = summary(since: since, wait: 2, lateWait: 30)
        XCTAssertEqual(text, "EXC_BAD_ACCESS (report: \(reports!)/\(try FileManager.default.contentsOfDirectory(atPath: reports)[0]))")
        XCTAssertLessThan(took, 1)
    }

    func testATrapInTheLogAnswersWithoutTheLateWait() throws {
        try "Fatal error: Index out of range\n".write(toFile: "\(slot.dir)/host.log", atomically: true, encoding: .utf8)
        try writeReport(for: "com.example.other")
        let (text, took) = summary(since: Date(), wait: 0.1, lateWait: 30)
        XCTAssertEqual(text, "Fatal error: Index out of range (no crash report from macOS this time)")
        XCTAssertLessThan(took, 5)
    }

    func testALateReportIsReadWhenTheLogHasNoAnswer() throws {
        let since = Date()
        let written = expectation(description: "report written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            try? self.writeReport(for: self.slot.slotID)
            written.fulfill()
        }
        let (text, took) = summary(since: since, wait: 0.1, lateWait: 10)
        wait(for: [written], timeout: 1)
        XCTAssertTrue(text?.hasPrefix("EXC_BAD_ACCESS (report: \(reports!)/") == true, text ?? "nil")
        XCTAssertGreaterThan(took, 0.3)
        XCTAssertLessThan(took, 5)
    }

    func testNoReportAndNoLogEndsAfterTheLateWait() {
        try? writeReport(for: "com.example.other")
        let (text, took) = summary(since: Date(), wait: 0.1, lateWait: 1)
        XCTAssertEqual(text, "the host process died, and macOS wrote no crash report within 1 s; run it in a simulator to see the crash")
        XCTAssertGreaterThanOrEqual(took, 1)
    }
}
