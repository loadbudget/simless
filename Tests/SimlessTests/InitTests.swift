// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// What `simless init` writes and removes: `.simless.json` only, and the kit
/// and App hook that older inits wrote, never a file it did not write.
final class InitTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-init-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(root)/Notes", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    let fresh = Config(project: "Notes.xcodeproj", scheme: "Notes", appTarget: "Notes", testTarget: "",
                       kitDir: nil, sourceDirs: ["Notes"])

    /// An App whose init() holds `initBody`, or with no init() for nil.
    func app(_ initBody: String?) -> String {
        """
        import SwiftUI

        @main
        struct NotesApp: App {\(initBody.map { "\n    init() {\n\($0)\n    }\n" } ?? "")
            var body: some Scene { WindowGroup { Text("Notes") } }
        }
        """
    }

    let appFile = "Notes/NotesApp.swift"
    let fixturesText = "// mine\nfunc simlessFixtures(_ r: SimlessRegistry) {}\n"

    func write(_ text: String, _ rel: String) throws {
        try FileManager.default.createDirectory(atPath: ("\(root)/\(rel)" as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: "\(root)/\(rel)", atomically: true, encoding: .utf8)
    }

    func read(_ rel: String) throws -> String { try String(contentsOfFile: "\(root)/\(rel)", encoding: .utf8) }

    /// Every file under the root, relative to it.
    func files() -> Set<String> {
        Set(FileManager.default.enumerator(atPath: root)!.compactMap { $0 as? String }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: "\(root)/\($0)", isDirectory: &isDir) && !isDir.boolValue
        })
    }

    /// An app as an older init left it: the kit, the fixtures file, and an
    /// App whose init() holds `initBody`.
    func olderInit(_ initBody: String) throws {
        try write(app(initBody), appFile)
        try write(try String(contentsOfFile: "\(Paths.toolRoot)/Templates/SimlessKit.swift", encoding: .utf8), "Notes/Simless/SimlessKit.swift")
        try write(fixturesText, "Notes/Simless/SimlessFixtures.swift")
    }

    func testFreshAppGetsOnlyTheConfig() throws {
        try write(app("        Analytics.start()"), appFile)
        let before = files()
        let (config, kept, removed) = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertFalse(kept)
        XCTAssertEqual(removed, [])
        XCTAssertEqual(files(), before.union([".simless.json"]))
        XCTAssertEqual(try read(appFile), app("        Analytics.start()"))
        // No kitDir key: the fixtures file's folder is the default.
        XCTAssertFalse(try read(".simless.json").contains("kitDir"))
        XCTAssertEqual(config.fixturesFile, "Notes/Simless/SimlessFixtures.swift")
        XCTAssertEqual(try Workspace.load(at: root).config.fixturesFile, "Notes/Simless/SimlessFixtures.swift")
    }

    func testRemovesKitAndHookAndKeepsFixtures() throws {
        try olderInit("        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif\n        Analytics.start()")
        let (_, _, removed) = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(removed, ["removed Notes/Simless/SimlessKit.swift: SimlessRuntime serves renders",
                                 "removed the App hook from Notes/NotesApp.swift"])
        XCTAssertFalse(exists("\(root)/Notes/Simless/SimlessKit.swift"))
        XCTAssertEqual(try read(appFile), app("        Analytics.start()"))
        XCTAssertEqual(try read("Notes/Simless/SimlessFixtures.swift"), fixturesText)
    }

    func testRemovesTheHookUnderTheOldGuard() throws {
        try olderInit("        #if DEBUG && os(iOS)\n        SimlessHost.startIfRequested()\n        #endif\n        Analytics.start()")
        _ = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(try read(appFile), app("        Analytics.start()"))
        XCTAssertEqual(try read("Notes/Simless/SimlessFixtures.swift"), fixturesText)
    }

    func testRemovesTheInitThatInitAdded() throws {
        // What an older init wrote into an App with no init().
        try olderInit("        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif")
        _ = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(try read(appFile), app(nil))
    }

    func testKeepsAnInitOfTheUsersOwnThatIsEmptyOnceTheHookIsOut() throws {
        // Not right after the declaration's brace: not the init() simless added.
        let head = "import SwiftUI\n\n@main\nstruct NotesApp: App {\n    let store = Store()\n\n    init() {\n"
        let tail = "    }\n\n    var body: some Scene { WindowGroup { Text(\"Notes\") } }\n}"
        try write(head + "        #if SIMLESS\n        SimlessHost.startIfRequested()\n        #endif\n" + tail, appFile)
        _ = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(try read(appFile), head + tail)
    }

    func testLeavesAnUnrelatedInit() throws {
        let text = app("        Analytics.start()\n        Store.shared.load()")
        try write(text, appFile)
        let (_, _, removed) = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(removed, [])
        XCTAssertEqual(try read(appFile), text)
    }

    func testLeavesAHookInAnotherForm() throws {
        // simless wrote the call only under a guard, each line with one indent.
        for body in ["        SimlessHost.startIfRequested()",
                     "        #if SIMLESS\n            SimlessHost.startIfRequested()\n        #endif",
                     "        #if SIMLESS && DEBUG\n        SimlessHost.startIfRequested()\n        #endif"] {
            try write(app(body), appFile)
            let (_, _, removed) = try initFiles(root: root, force: true, fresh: fresh)
            XCTAssertEqual(removed, ["left SimlessHost.startIfRequested() in Notes/NotesApp.swift: it is not in the form simless init wrote; remove it by hand"])
            XCTAssertEqual(try read(appFile), app(body))
        }
    }

    func testTheKitsOfEachVersionAreSimlessKits() {
        // The first kit started with the marker; later ones with a licence header.
        XCTAssertTrue(isSimlessKit(kitMarker + "\n// Generated by `simless init`.\n#if DEBUG && os(iOS)\n"))
        XCTAssertTrue(isSimlessKit((try? String(contentsOfFile: "\(Paths.toolRoot)/Templates/SimlessKit.swift", encoding: .utf8)) ?? ""))
        // The marker after code is not the kit's.
        XCTAssertFalse(isSimlessKit("// mine\nlet s = 1\n" + kitMarker + "\n"))
    }

    func testLeavesAKitFileSimlessDidNotWrite() throws {
        try write("// my own SimlessKit\n", "Notes/Simless/SimlessKit.swift")
        let (_, _, removed) = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertEqual(removed, ["left Notes/Simless/SimlessKit.swift: simless did not write it"])
        XCTAssertEqual(try read("Notes/Simless/SimlessKit.swift"), "// my own SimlessKit\n")
    }

    func testAKeptConfigNamesWhereTheKitIs() throws {
        let config = #"{"project": "Notes.xcodeproj", "scheme": "Notes", "appTarget": "Notes", "testTarget": "", "kitDir": "Debug/Simless", "sourceDirs": ["Notes", "Debug"], "device": "iphone"}"#
        try write(config, ".simless.json")
        try write(kitMarker + "\n", "Debug/Simless/SimlessKit.swift")
        let (_, kept, removed) = try initFiles(root: root, force: false, fresh: fresh)
        XCTAssertTrue(kept)
        XCTAssertEqual(try read(".simless.json"), config)
        XCTAssertEqual(removed, ["removed Debug/Simless/SimlessKit.swift: SimlessRuntime serves renders"])
    }

    func testForceKeepsTheOldKitDir() throws {
        try write(#"{"project": "Old.xcodeproj", "scheme": "Old", "appTarget": "Old", "testTarget": "", "kitDir": "Debug/Simless", "sourceDirs": ["Notes"], "device": "iphone"}"#,
                  ".simless.json")
        let (config, kept, _) = try initFiles(root: root, force: true, fresh: fresh)
        XCTAssertFalse(kept)
        XCTAssertEqual(config.project, "Notes.xcodeproj")
        XCTAssertEqual(try Workspace.load(at: root).config.kitDir, "Debug/Simless")
    }

    func testAnUnreadableConfigStopsInitWithoutForce() throws {
        try write("{", ".simless.json")
        XCTAssertThrowsError(try initFiles(root: root, force: false, fresh: fresh))
        XCTAssertEqual(try read(".simless.json"), "{")
        _ = try initFiles(root: root, force: true, fresh: fresh)
        XCTAssertEqual(try Workspace.load(at: root).config.project, "Notes.xcodeproj")
    }

    func testABuildWithoutTheKitLeavesTheFixturesFileOut() {
        XCTAssertEqual(Workspace.fixturesExclusion(kitInApp: false, fixturesFile: "Notes/Simless/SimlessFixtures.swift"),
                       ["EXCLUDED_SOURCE_FILE_NAMES=$(inherited) SimlessFixtures.swift"])
        XCTAssertEqual(Workspace.fixturesExclusion(kitInApp: true, fixturesFile: "Notes/Simless/SimlessFixtures.swift"), [])
    }

    func testTheDefaultFixturesFolder() {
        var c = fresh
        c.sourceDirs = ["."]
        XCTAssertEqual(c.fixturesFile, "Simless/SimlessFixtures.swift")
        c.sourceDirs = []
        XCTAssertEqual(c.fixturesFile, "Simless/SimlessFixtures.swift")
    }
}
