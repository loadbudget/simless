// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// How long `CrashReport.summary` looks for macOS's crash report, which
/// report it takes, and what answers when the report is late or never comes.
final class CrashReportWaitTests: XCTestCase {
    var root: String!
    var reports: String!
    var slot: SlotRecord!
    let noReport = "the host process died, and macOS wrote no crash report within"

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

    /// A report as macOS writes it: a JSON header line, then the JSON body,
    /// with `captureTime` in macOS's format unless `captured` is nil. The
    /// format keeps 0.1 ms, so the default is 10 ms ahead of a `since` just taken.
    @discardableResult
    func writeReport(for bundleID: String? = nil, exception: String = "EXC_BAD_ACCESS", captured: Date? = Date() + 0.01,
                     symbols: [String] = ["main"]) throws -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        let capture = captured.map { #""captureTime": "\#(format.string(from: $0))", "# } ?? ""
        let frames = symbols.map { #"{"symbol": "\#($0)"}"# }.joined(separator: ", ")
        let path = "\(reports!)/App-\(UUID().uuidString).ips"
        try """
            {"bundleID": "\(bundleID ?? slot.slotID)"}
            {\(capture)"exception": {"type": "\(exception)"}, "threads": [{"triggered": true, "frames": [\(frames)]}]}
            """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func writeLog(_ text: String) throws {
        try text.write(toFile: "\(slot.dir)/host.log", atomically: true, encoding: .utf8)
    }

    func summary(since: Date, wait: Double, lateWait: Double) -> (text: String, symbols: [String], took: Double) {
        let start = now()
        let crash = CrashReport.summary(slot: slot, since: since, wait: wait, lateWait: lateWait, dir: reports)
        return (crash.text, crash.symbols, now() - start)
    }

    func testCaptureTimeReadsMacOSFormat() {
        let date = CrashReport.captureTime(["captureTime": "2026-10-24 18:28:58.0209 +0200"])
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, ISO8601DateFormatter().date(from: "2026-10-24T16:28:58Z")!.timeIntervalSince1970 + 0.0209, accuracy: 0.001)
        XCTAssertNil(CrashReport.captureTime([:]))
        XCTAssertNil(CrashReport.captureTime(["captureTime": "2026-10-24T18:28:58Z"]))
    }

    func testTheNewestReportInTheFirstWaitIsReadWithItsSymbols() throws {
        let since = Date()
        try writeReport(exception: "EXC_CRASH")
        Thread.sleep(forTimeInterval: 0.05)
        let path = try writeReport(symbols: ["$s3App4mainyyF", "start"])
        let (text, symbols, took) = summary(since: since, wait: 2, lateWait: 30)
        XCTAssertEqual(text, "EXC_BAD_ACCESS (report: \(path))")
        XCTAssertEqual(symbols, ["$s3App4mainyyF", "start"])
        XCTAssertLessThan(took, 1)
    }

    func testATrapInTheLogAnswersWithoutTheLateWait() throws {
        let since = Date()
        try writeLog("Fatal error: Index out of range\n")
        try writeReport(for: "com.example.other")
        let (text, symbols, took) = summary(since: since, wait: 0.1, lateWait: 30)
        XCTAssertEqual(text, "Fatal error: Index out of range (no crash report from macOS this time)")
        XCTAssertEqual(symbols, [])
        XCTAssertLessThan(took, 5)
    }

    func testHandlerFramesInTheLogAnswerWithoutTheLateWait() throws {
        let since = Date()
        try writeLog("simless-crash-frame: _sigtramp\nsimless-crash-frame: objc_exception_throw\nsimless-crash-frame: main\n")
        let (text, symbols, took) = summary(since: since, wait: 0.1, lateWait: 30)
        XCTAssertEqual(text, "crashed in objc_exception_throw ← main (no crash report from macOS this time; frames from the host's log)")
        XCTAssertEqual(symbols, [])
        XCTAssertLessThan(took, 5)
    }

    func testALateReportIsReadWhenTheLogHasNoAnswer() throws {
        let since = Date()
        let written = expectation(description: "report written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            _ = try? self.writeReport()
            written.fulfill()
        }
        let (text, symbols, took) = summary(since: since, wait: 0.1, lateWait: 10)
        wait(for: [written], timeout: 1)
        XCTAssertTrue(text.hasPrefix("EXC_BAD_ACCESS (report: \(reports!)/"), text)
        XCTAssertEqual(symbols, ["main"])
        XCTAssertGreaterThan(took, 0.3)
        XCTAssertLessThan(took, 5)
    }

    func testNoReportOfTheSlotEndsAfterTheLateWait() throws {
        let since = Date()
        try writeReport(for: "com.example.other")
        let (text, symbols, took) = summary(since: since, wait: 0.1, lateWait: 1)
        XCTAssertEqual(text, "\(noReport) 1 s; run it in a simulator to see the crash")
        XCTAssertEqual(symbols, [])
        XCTAssertGreaterThanOrEqual(took, 1)
        XCTAssertLessThan(took, 3)
    }

    func testAReportWrittenBeforeSinceIsIgnored() throws {
        try writeReport()
        Thread.sleep(forTimeInterval: 0.05)
        let (text, _, _) = summary(since: Date(), wait: 0.1, lateWait: 0.3)
        XCTAssertTrue(text.hasPrefix(noReport), text)
    }

    func testAReportCapturedBeforeSinceIsIgnored() throws {
        let since = Date()
        try writeReport(captured: since - 30)
        let (text, _, _) = summary(since: since, wait: 0.1, lateWait: 0.3)
        XCTAssertTrue(text.hasPrefix(noReport), text)
    }

    func testAReportWithoutCaptureTimeIsIgnored() throws {
        let since = Date()
        try writeReport(captured: nil)
        let (text, _, _) = summary(since: since, wait: 0.1, lateWait: 0.3)
        XCTAssertTrue(text.hasPrefix(noReport), text)
    }
}
