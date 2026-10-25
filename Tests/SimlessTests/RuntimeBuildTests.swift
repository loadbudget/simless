// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The cache of SimlessRuntime builds: a build is reused only by the compiler
/// that made it, and only when its module is there too.
final class RuntimeBuildTests: XCTestCase {
    let sources = [(path: "/r/Runtime.swift", mtime: "1"), (path: "/r/interpose.c", mtime: "2")]

    func testAnotherSwiftCompilerGetsAnotherBuild() {
        let a = RuntimeBuild.stamp(version: "1.0", xcode: "Xcode 27.0", swiftc: "Apple Swift version 6.4", sources: sources)
        let b = RuntimeBuild.stamp(version: "1.0", xcode: "Xcode 27.0", swiftc: "Apple Swift version 6.4.1", sources: sources)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, RuntimeBuild.stamp(version: "1.0", xcode: "Xcode 27.0", swiftc: "Apple Swift version 6.4", sources: sources))
    }

    func testAHalfBuiltFolderIsBuiltAgainFromEmpty() throws {
        let dir = NSTemporaryDirectory() + "simless-runtime-build-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(dir)/native", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        // A library, and a signed copy of it, but no module.
        fm.createFile(atPath: "\(dir)/SimlessRuntime.dylib", contents: Data("old".utf8))
        fm.createFile(atPath: "\(dir)/native/SimlessRuntime.dylib", contents: Data("old".utf8))
        var builds = 0
        let build = {
            builds += 1
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir), [])
            fm.createFile(atPath: "\(dir)/SimlessRuntime.swiftmodule", contents: Data())
            fm.createFile(atPath: "\(dir)/SimlessRuntime.dylib", contents: Data("new".utf8))
        }
        try RuntimeBuild.ensureBuilt(dir, build: build)
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(fm.fileExists(atPath: "\(dir)/native"))
        try RuntimeBuild.ensureBuilt(dir, build: build)
        XCTAssertEqual(builds, 1)
    }
}
