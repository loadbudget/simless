// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The number in a slot's bundle id (<id>.simless<n>) comes from the path of
/// its worktree, so two worktrees never share an app container.
final class SlotNumberTests: XCTestCase {
    let first = "/Users/dev/worktrees/app-a", second = "/Users/dev/worktrees/app-b"

    func port(_ used: Set<Int>) -> Int { (47800...).first { !used.contains($0) }! }

    func testAWorktreeKeepsItsNumber() {
        XCTAssertEqual(slotNumber(forWorktree: first), slotNumber(forWorktree: first))
        XCTAssertNotEqual(slotNumber(forWorktree: first), slotNumber(forWorktree: second))
    }

    /// SimlessAgent places a patch only in a container whose id ends in `.simless[0-9]+`.
    func testTheBundleIDStillEndsInDigits() throws {
        var state = GlobalState()
        let (slot, _) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        XCTAssertNotNil(slot.slotID.range(of: #"\.simless[0-9]+$"#, options: .regularExpression))
    }

    func testTwoWorktreesTakeTheirOwnNumbersAndPorts() throws {
        var state = GlobalState()
        let (a, _) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        let (b, _) = try state.assign(bundleBase: "com.example.notes", worktree: second, kind: nil, port: port)
        XCTAssertEqual(a.n, slotNumber(forWorktree: first))
        XCTAssertEqual(b.n, slotNumber(forWorktree: second))
        XCTAssertNotEqual(a.port, b.port)
    }

    func testATestSlotSharesTheNumberOfItsRenderSlot() throws {
        var state = GlobalState()
        let (render, _) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        let (test, _) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: "test", port: port)
        XCTAssertEqual(test.slotID, render.slotID + "-test")
    }

    func testAskingAgainReturnsTheSameSlot() throws {
        var state = GlobalState()
        let (a, _) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        let (again, replaced) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        XCTAssertEqual(again.slotID, a.slotID)
        XCTAssertEqual(again.port, a.port)
        XCTAssertTrue(replaced.isEmpty)
        XCTAssertEqual(state.slots.count, 1)
    }

    /// A slot from the old lowest-free numbering goes back to the caller to remove.
    func testASlotUnderAnOldNumberIsReplaced() throws {
        var state = GlobalState(slots: [SlotRecord(bundleBase: "com.example.notes", n: 1, worktree: first, port: 47800)])
        let (slot, replaced) = try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port)
        XCTAssertEqual(replaced.map(\.slotID), ["com.example.notes.simless1"])
        XCTAssertEqual(state.slots.map(\.slotID), [slot.slotID])
    }

    func testTwoWorktreesOnOneNumberThrow() {
        let taken = SlotRecord(bundleBase: "com.example.notes", n: slotNumber(forWorktree: first), worktree: second, port: 47800)
        var state = GlobalState(slots: [taken])
        XCTAssertThrowsError(try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil, port: port))
        XCTAssertEqual(state.slots.map(\.worktree), [second])
    }

    /// Each worktree keeps its slots in its own file, so the clash is with another file's slot.
    func testAClashWithAnotherWorktreesFileThrows() {
        let taken = SlotRecord(bundleBase: "com.example.notes", n: slotNumber(forWorktree: first), worktree: second, port: 47800)
        var state = GlobalState()
        XCTAssertThrowsError(try state.assign(bundleBase: "com.example.notes", worktree: first, kind: nil,
                                              others: [taken], port: port))
        XCTAssertTrue(state.slots.isEmpty)
    }
}
