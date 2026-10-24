// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Which code serves renders: SimlessKit when the app carries it, else
/// SimlessRuntime. The launch and the dylibs simless compiles follow the same
/// choice, so one server listens and the dylibs fill its registry.
final class RenderServerTests: XCTestCase {
    var root: String!
    var ws: Workspace!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-render-server-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(root!)/Src/Simless", withIntermediateDirectories: true)
        try """
            {"project": "App.xcodeproj", "scheme": "App", "appTarget": "App", "testTarget": "", "kitDir": "Src/Simless", "sourceDirs": ["Src"], "device": "iphone"}
            """.write(toFile: "\(root!)/.simless.json", atomically: true, encoding: .utf8)
        ws = try Workspace.load(at: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func slot(builtWithKit: Bool?) -> SlotRecord {
        SlotRecord(bundleBase: "com.example.app", n: 1, worktree: root, port: 50000, builtWithKit: builtWithKit)
    }

    func writeKit() throws {
        try "// kit\n".write(toFile: "\(root!)/\(ws.config.kitFile)", atomically: true, encoding: .utf8)
    }

    /// The environment each launch path hands the host: `open --env` for dfi,
    /// posix_spawn's for native.
    func launchEnvironments(_ slot: SlotRecord) -> (dfi: [String], native: [String: String]) {
        (Slots.openCommand(slot, app: "/A.app", idleMinutes: 30, extra: []),
         Native.spawnEnvironment(slot, extra: RuntimeHost.renderEnvironment(slot)))
    }

    func testABuildWithoutTheKitStartsTheRuntimeServerOnBothLaunchPaths() {
        let (dfi, native) = launchEnvironments(slot(builtWithKit: false))
        XCTAssertTrue(dfi.contains("SIMLESS_RENDER_SERVER=1"))
        XCTAssertEqual(native["SIMLESS_RENDER_SERVER"], "1")
        XCTAssertEqual(Array(dfi.suffix(5)), ["--args", "--simless-port", "50000", "--simless-idle", "1800"])
    }

    /// The kit was deleted after the build: the installed app still serves
    /// renders, so the runtime must not start a second server.
    func testABuildWithTheKitKeepsItsServerAfterTheKitIsDeleted() {
        XCTAssertFalse(ws.kitInApp)
        let (dfi, native) = launchEnvironments(slot(builtWithKit: true))
        XCTAssertFalse(dfi.contains { $0.hasPrefix("SIMLESS_RENDER_SERVER") })
        XCTAssertNil(native["SIMLESS_RENDER_SERVER"])
    }

    /// The kit was added after a build without it: the runtime still serves.
    func testABuildWithoutTheKitKeepsTheRuntimeServerAfterTheKitIsAdded() throws {
        try writeKit()
        XCTAssertTrue(ws.kitInApp)
        let (dfi, native) = launchEnvironments(slot(builtWithKit: false))
        XCTAssertTrue(dfi.contains("SIMLESS_RENDER_SERVER=1"))
        XCTAssertEqual(native["SIMLESS_RENDER_SERVER"], "1")
    }

    /// A record from before the mode was kept is from a build with the kit.
    func testARecordWithNoModeIsABuildWithTheKit() {
        XCTAssertNil(launchEnvironments(slot(builtWithKit: nil)).native["SIMLESS_RENDER_SERVER"])
    }

    func testDeletingOrAddingTheKitMakesReloadBuildTheApp() throws {
        XCTAssertEqual(fullBuildReason(ws: ws, slot: slot(builtWithKit: true), files: []), "SimlessKit deleted")
        XCTAssertNil(fullBuildReason(ws: ws, slot: slot(builtWithKit: false), files: ["\(root!)/Src/A.swift"]))
        try writeKit()
        XCTAssertEqual(fullBuildReason(ws: ws, slot: slot(builtWithKit: false), files: []), "SimlessKit added")
        XCTAssertNil(fullBuildReason(ws: ws, slot: slot(builtWithKit: true), files: ["\(root!)/Src/A.swift"]))
        XCTAssertEqual(fullBuildReason(ws: ws, slot: slot(builtWithKit: true), files: ["\(root!)/\(ws.config.kitFile)"]),
                       "SimlessKit changed")
    }

    func testPatchSourcesImportTheRuntimeOnlyWithoutTheKit() {
        XCTAssertEqual(Patch.sourceHeader(modules: ["App"], kitInApp: true), "@testable import App\n")
        XCTAssertEqual(Patch.sourceHeader(modules: ["App"], kitInApp: false), "import SimlessRuntime; @testable import App\n")
    }

    /// Compiler errors are mapped back by one line per module, in both modes.
    func testTheHeaderHasOneLinePerModule() {
        for kitInApp in [true, false] {
            let header = Patch.sourceHeader(modules: ["App", "Feature", "Models"], kitInApp: kitInApp)
            XCTAssertEqual(header.filter { $0 == "\n" }.count, 3)
        }
    }

    func testAPatchWithoutTheKitCompilesForTheRuntimesIOS() {
        XCTAssertEqual(Patch.target(deploymentTarget: "16.4", kitInApp: true), "16.4")
        XCTAssertEqual(Patch.target(deploymentTarget: "16.4", kitInApp: false), "17.0")
        XCTAssertEqual(Patch.target(deploymentTarget: "17.0", kitInApp: false), "17.0")
        XCTAssertEqual(Patch.target(deploymentTarget: "18.2", kitInApp: false), "18.2")
    }

    /// Without the kit, the fixtures reach the host only in this dylib.
    func testWithNoPreviewTheFixturesStillGetALibraryWhenAsked() throws {
        var input = PatchScope.Input()
        input.sources = ["Notes.swift": "struct Notes {}\n"]
        var compiled = 0
        let none = try Previews.compileLeavingOut(input) { _, _ in compiled += 1; return "/tmp/previews.dylib" }
        XCTAssertNil(none.dylib)
        XCTAssertEqual(compiled, 0)
        let fixtures = try Previews.compileLeavingOut(input, alwaysBuild: true) { gen, _ in
            XCTAssertTrue(gen.calls.isEmpty)
            compiled += 1
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(fixtures.dylib, "/tmp/previews.dylib")
        XCTAssertEqual(compiled, 1)
    }

    func setPreviews(_ on: Bool) throws {
        try """
            {"project": "App.xcodeproj", "scheme": "App", "appTarget": "App", "testTarget": "", "kitDir": "Src/Simless", "sourceDirs": ["Src"], "device": "iphone", "previews": \(on)}
            """.write(toFile: "\(root!)/.simless.json", atomically: true, encoding: .utf8)
        ws = try Workspace.load(at: root)
    }

    func writeFixtures() throws {
        try "// fixtures\n".write(toFile: "\(root!)/\(ws.config.fixturesFile)", atomically: true, encoding: .utf8)
    }

    /// No kit and no fixtures file: the fixtures are the #Preview blocks. The
    /// dylib leaves out the fixtures file and the call to `simlessFixtures`,
    /// and still registers each preview.
    func testWithoutTheKitAndTheFixturesFileTheDylibHasThePreviewsAlone() throws {
        try """
            import SwiftUI
            struct Card: View { var body: some View { Text("card") } }
            #Preview("Plain") { Card() }
            """.write(toFile: "\(root!)/Src/Card.swift", atomically: true, encoding: .utf8)
        XCTAssertNil(Patch.fixturesFile(ws: ws, kitInApp: false))
        let entry = Patch.entrySource(appModule: "App", kitInApp: false, callsFixtures: false, prelude: "", entry: "        simlessRegisterPreviews(r)")
        XCTAssertFalse(entry.contains("simlessFixtures"))
        XCTAssertTrue(entry.contains("simlessRegisterPreviews(r)"))
        var compiled: [String] = []
        let m = try Previews.compileLeavingOut(PatchScope.input(ws: ws, edited: []), alwaysBuild: true) { gen, _ in
            compiled = gen.texts.keys.map { ($0 as NSString).lastPathComponent }
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(m.entries.map(\.name), ["Card.Plain"])
        XCTAssertEqual(compiled, ["Card.swift"])
    }

    /// With the kit, the fixtures file is still part of every dylib: a missing
    /// one fails the compile, as before.
    func testWithTheKitTheFixturesFileIsAlwaysCompiled() throws {
        XCTAssertEqual(Patch.fixturesFile(ws: ws, kitInApp: true), "\(root!)/\(ws.config.fixturesFile)")
        XCTAssertTrue(Patch.entrySource(appModule: "App", kitInApp: true, callsFixtures: true, prelude: "", entry: "")
            .contains("        simlessFixtures(r)\n"))
        try writeFixtures()
        XCTAssertEqual(Patch.fixturesFile(ws: ws, kitInApp: false), "\(root!)/\(ws.config.fixturesFile)")
    }

    func testUpRefusesAnAppWithNoKitNoFixturesFileAndNoPreviews() throws {
        try setPreviews(false)
        XCTAssertThrowsError(try ws.checkFixtureSources()) { error in
            XCTAssertTrue("\(error)".contains("no fixtures"), "\(error)")
            XCTAssertTrue("\(error)".contains("\"previews\": false"), "\(error)")
        }
        try setPreviews(true)
        XCTAssertNoThrow(try ws.checkFixtureSources())
        try setPreviews(false)
        try writeFixtures()
        XCTAssertNoThrow(try ws.checkFixtureSources())
        try FileManager.default.removeItem(atPath: "\(root!)/\(ws.config.fixturesFile)")
        try writeKit()
        XCTAssertNoThrow(try ws.checkFixtureSources())
    }
}
