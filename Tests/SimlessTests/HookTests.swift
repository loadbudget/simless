// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The call `simless init` adds to the App's init(), and its guard.
final class HookTests: XCTestCase {
    var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-hook-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: dir)
    }

    func app(_ initBody: String) -> String {
        """
        import SwiftUI

        @main
        struct NotesApp: App {
            init() {
        \(initBody)
            }

            var body: some Scene { WindowGroup { Text("Notes") } }
        }
        """
    }

    func write(_ text: String) throws -> String {
        let path = "\(dir)/NotesApp.swift"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testAddsTheCallUnderTheSimlessCondition() throws {
        let path = try write(app("        Analytics.start()"))
        XCTAssertEqual(try insertHook(in: dir), "added to init() in NotesApp.swift")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("#if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif\n"))
    }

    func testMovesACallFromTheOldGuard() throws {
        let path = try write(app("        #if DEBUG && os(iOS)\n        SimlessHost.startIfRequested()\n        #endif"))
        XCTAssertEqual(try insertHook(in: dir), "moved under #if SIMLESS in NotesApp.swift")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, app("        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif"))
    }

    func testLeavesACallUnderTheNewGuard() throws {
        let path = try write(app("        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif"))
        XCTAssertEqual(try insertHook(in: dir), "already present in NotesApp.swift")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       app("        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif"))
    }
}
