// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Each worktree keeps its slot records and slot folders in its own work folder.
final class WorktreeStateTests: XCTestCase {
    var cache = ""
    let first = "/Users/dev/notes", second = "/Users/dev/notes-feature"

    override func setUpWithError() throws {
        cache = NSTemporaryDirectory() + "simless-state-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: cache)
    }

    func record(_ worktree: String, kind: String? = nil) -> SlotRecord {
        var r = SlotRecord(bundleBase: "com.example.notes", n: slotNumber(forWorktree: worktree), worktree: worktree, port: 47800)
        r.kind = kind
        return r
    }

    func testEachWorktreeLoadsOnlyItsOwnSlots() throws {
        try GlobalState(slots: [record(first), record(first, kind: "test")]).save(worktree: first, cache: cache)
        try GlobalState(slots: [record(second)]).save(worktree: second, cache: cache)

        XCTAssertEqual(GlobalState.load(worktree: first, cache: cache).slots.map(\.slotID),
                       [record(first).slotID, record(first, kind: "test").slotID])
        XCTAssertEqual(GlobalState.load(worktree: second, cache: cache).slots.map(\.slotID), [record(second).slotID])
        XCTAssertTrue(exists(Paths.statePath(forWorktree: first, cache: cache)))
        XCTAssertTrue(Paths.statePath(forWorktree: first, cache: cache).hasPrefix("\(cache)/work/"))
    }

    func testAllReadsEveryWorktree() throws {
        try GlobalState(slots: [record(first)]).save(worktree: first, cache: cache)
        try GlobalState(slots: [record(second)]).save(worktree: second, cache: cache)

        XCTAssertEqual(Set(GlobalState.all(cache: cache).map(\.slotID)), [record(first).slotID, record(second).slotID])
    }

    func testAllIsEmptyWithNoWorkFolder() {
        XCTAssertTrue(GlobalState.all(cache: cache).isEmpty)
    }

    func testSlotFolderIsInsideItsWorktreesWorkFolder() {
        let r = record(first, kind: "ui1")
        XCTAssertEqual(r.dir, "\(Paths.workDir(forWorktree: first))/slots/\(r.slotID)")
    }

    func testLegacyCleanupRemovesEveryRecordAndUnnamedFolder() {
        let legacy = "/cache/slots"
        let state = GlobalState(slots: [record(first), record(second)])
        let plan = Cleanup.legacySlotDirs(state, folders: [record(first).slotID, "com.example.notes.simless3"], legacySlots: legacy)

        XCTAssertEqual(plan.map(\.dir), ["\(legacy)/\(record(first).slotID)", "\(legacy)/\(record(second).slotID)",
                                         "\(legacy)/com.example.notes.simless3"])
        XCTAssertEqual(plan.map { $0.slot?.slotID }, [record(first).slotID, record(second).slotID, nil])
    }
}
