// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The OS picks a host's port, so a worktree needs no list of other worktrees' ports.
final class PortTests: XCTestCase {
    func testTheOSGivesAFreePort() throws {
        let port = try freePort()
        XCTAssertTrue(portIsFree(port))
    }

    func testAPortAStoppedHostHoldsIsNotGiven() throws {
        let first = try freePort()
        XCTAssertNotEqual(try freePort(avoiding: [first]), first)
    }

    /// A stopped host's port that another program took since.
    func testASlotWhosePortIsRefusedGetsANewOne() throws {
        let worktree = "/Users/dev/worktrees/app-a"
        var state = GlobalState(slots: [SlotRecord(bundleBase: "com.example.notes", n: slotNumber(forWorktree: worktree),
                                                   worktree: worktree, port: 47800)])
        let (slot, replaced) = try state.assign(bundleBase: "com.example.notes", worktree: worktree, kind: nil,
                                                keep: { _ in false }, port: { _ in 51234 })
        XCTAssertEqual(slot.port, 51234)
        XCTAssertEqual(state.slots.map(\.port), [51234])
        XCTAssertTrue(replaced.isEmpty)
    }
}
