// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// `clean --worktree` gets a path from a tool that may name it another way than git does.
final class CanonicalPathTests: XCTestCase {
    var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-canonical-\(UUID().uuidString)"
        try mkdirp("\(dir)/real/app")
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/link", withDestinationPath: "\(dir)/real")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testASymlinkAndATrailingSlashNameTheSameWorktree() {
        XCTAssertEqual(canonicalPath("\(dir)/link/app/"), canonicalPath("\(dir)/real/app"))
    }

    /// The worktree is gone, so only its parent can be resolved.
    func testARemovedWorktreeKeepsItsNameUnderItsResolvedParent() throws {
        try FileManager.default.removeItem(atPath: "\(dir)/real/app")
        XCTAssertEqual(canonicalPath("\(dir)/link/app"), canonicalPath("\(dir)/real") + "/app")
    }

    /// `/tmp` is a symlink to `/private/tmp`, and git names a worktree there by the latter.
    func testTheTemporaryFolderResolvesUnderPrivate() {
        XCTAssertTrue(canonicalPath("/tmp/simless-gone-\(UUID().uuidString)").hasPrefix("/private/tmp/"))
    }
}
