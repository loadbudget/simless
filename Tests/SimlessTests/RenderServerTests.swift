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
        try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: root))
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

    /// The previews dylib of the last `up`, as `Previews.build` records it.
    func writePreviewsManifest(dylib: Bool) throws {
        try FileManager.default.createDirectory(atPath: Previews.dir(ws), withIntermediateDirectories: true)
        let path = "\(Previews.dir(ws))/previews.dylib"
        if dylib { try "dylib".write(toFile: path, atomically: true, encoding: .utf8) }
        try JSONEncoder().encode(Previews.Manifest(dylib: dylib ? path : nil, entries: []))
            .write(to: URL(fileURLWithPath: Previews.manifestPath(ws)))
    }

    func testDeletingOrAddingTheKitMakesReloadBuildTheApp() throws {
        try writePreviewsManifest(dylib: true)
        XCTAssertEqual(fullBuildReason(ws: ws, slot: slot(builtWithKit: true), files: []), "SimlessKit deleted")
        let kitless = slot(builtWithKit: false)
        try FileManager.default.createDirectory(atPath: kitless.dir, withIntermediateDirectories: true)
        try RuntimeHost.recordInjected(kitless, build: "/r/x")
        XCTAssertNil(fullBuildReason(ws: ws, slot: kitless, files: ["\(root!)/Src/A.swift"], currentRuntime: { "/r/x" }))
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

    /// A refused `up` writes nothing: the snapshot still names the build the
    /// host runs, so the next `reload` still sees an edit made before it.
    func testARefusedUpKeepsTheEditsForTheNextReload() throws {
        // `up` finds the workspace from the current folder, under the path the
        // system gives for it (/private/var for /var).
        let cwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(root)
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        root = try XCTUnwrap(Workspace.findRoot())
        ws = try Workspace.load(at: root)
        try "struct A {}\n".write(toFile: "\(root!)/Src/A.swift", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: ws.work, withIntermediateDirectories: true)
        _ = try ws.snapshotSources()
        try "struct A { var b = 1 }\n".write(toFile: "\(root!)/Src/A.swift", atomically: true, encoding: .utf8)
        try setPreviews(false)
        let before = FileManager.default.contents(atPath: ws.snapshotPath)
        XCTAssertThrowsError(try cmdUp(Args([]))) { XCTAssertTrue("\($0)".contains("no fixtures"), "\($0)") }
        XCTAssertEqual(FileManager.default.contents(atPath: ws.snapshotPath), before)
        XCTAssertFalse(exists("\(ws.work)/worktree.txt"))
        XCTAssertEqual(ws.changedSources().map { ($0 as NSString).lastPathComponent }, ["A.swift"])
    }

    /// Without the kit, the last round can leave out the last preview: the
    /// fixtures still get a library, or the manifest says why they have none.
    func testWithoutTheKitLeavingOutEveryPreviewStillBuildsTheFixtures() throws {
        var input = PatchScope.Input()
        input.sources = ["Card.swift": "import SwiftUI\nstruct Card: View { var body: some View { Text(\"c\") } }\n#Preview(\"Plain\") { Card() }\n"]
        let previewsFail: (Previews.Generated, String) throws -> String = { gen, _ in
            guard gen.calls.isEmpty else { throw SimlessError("patch compile failed\nCard.swift:3:1: error: no such thing") }
            return "/tmp/previews.dylib"
        }
        let fixtures = try Previews.compileLeavingOut(input, rounds: 1, alwaysBuild: true, compile: previewsFail)
        XCTAssertEqual(fixtures.dylib, "/tmp/previews.dylib")
        XCTAssertNil(fixtures.failure)
        XCTAssertNil(try Previews.compileLeavingOut(input, rounds: 1, compile: previewsFail).dylib)

        let allFail: (Previews.Generated, String) throws -> String = { _, _ in
            throw SimlessError("patch compile failed\nCard.swift:3:1: error: no such thing")
        }
        let none = try Previews.compileLeavingOut(input, rounds: 1, alwaysBuild: true, compile: allFail)
        XCTAssertNil(none.dylib)
        XCTAssertEqual(none.failure, "every preview was left out for compile errors (1), and the fixtures alone don't compile either; Card.swift:3:1: error: no such thing")
    }

    /// A folder that stands for a runtime build, with a module whose text
    /// names the build.
    func runtimeBuild(_ name: String) throws -> String {
        let dir = "\(root!)/runtime/\(name)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try name.write(toFile: "\(dir)/SimlessRuntime.swiftmodule", atomically: true, encoding: .utf8)
        return dir
    }

    func moduleText(_ slot: SlotRecord) -> String? { try? String(contentsOfFile: RuntimeHost.module(slot), encoding: .utf8) }

    func testTheSlotsModuleFollowsTheBuildItIsAskedFor() throws {
        let s = slot(builtWithKit: false)
        let a = try runtimeBuild("a"), b = try runtimeBuild("b")
        XCTAssertEqual(try RuntimeHost.currentModule(s, build: a), RuntimeHost.moduleDir(s))
        XCTAssertEqual(moduleText(s), "a")
        _ = try RuntimeHost.currentModule(s, build: b)
        XCTAssertEqual(moduleText(s), "b")
        // A copy of the same build is not copied again.
        try "b, kept".write(toFile: RuntimeHost.module(s), atomically: true, encoding: .utf8)
        _ = try RuntimeHost.currentModule(s, build: b)
        XCTAssertEqual(moduleText(s), "b, kept")
    }

    /// Without the kit, the host's dylibs bind to the runtime it injects, so
    /// a reload across a runtime change builds the app again.
    func testWithoutTheKitAChangedRuntimeMakesReloadBuildTheApp() throws {
        try writePreviewsManifest(dylib: true)
        let kitless = slot(builtWithKit: false)
        XCTAssertEqual(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }), "SimlessRuntime changed")
        try FileManager.default.createDirectory(atPath: kitless.dir, withIntermediateDirectories: true)
        try RuntimeHost.recordInjected(kitless, build: "/r/x")
        XCTAssertNil(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }))
        XCTAssertEqual(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/y" }), "SimlessRuntime changed")
        try writeKit()
        XCTAssertNil(fullBuildReason(ws: ws, slot: slot(builtWithKit: true), files: [], currentRuntime: { "/r/y" }))
    }

    /// After an `up` without the kit whose previews failed, the host has no
    /// fixtures: a reload builds them, and does not patch a host without them.
    func testWithoutTheKitAReloadAfterFailedFixturesBuildsTheApp() throws {
        let kitless = slot(builtWithKit: false)
        try FileManager.default.createDirectory(atPath: kitless.dir, withIntermediateDirectories: true)
        try RuntimeHost.recordInjected(kitless, build: "/r/x")
        XCTAssertEqual(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }), "the fixtures weren't built")
        try writePreviewsManifest(dylib: false)
        XCTAssertEqual(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }), "the fixtures weren't built")
        try writePreviewsManifest(dylib: true)
        XCTAssertNil(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }))
        try FileManager.default.removeItem(atPath: "\(Previews.dir(ws))/previews.dylib")
        XCTAssertEqual(fullBuildReason(ws: ws, slot: kitless, files: [], currentRuntime: { "/r/x" }), "the fixtures weren't built")
    }

    /// A relaunch (locale, crash retry, undo, native warm reload) of a host
    /// without the kit keeps its runtime, so the dylibs it loads match it.
    func testALaunchWithoutTheKitKeepsTheRuntimeTheHostWasBuiltWith() throws {
        let kitless = slot(builtWithKit: false)
        XCTAssertFalse(RuntimeHost.keepsInjectedRuntime(kitless, current: "/r/y"), "no runtime in the slot yet")
        try FileManager.default.createDirectory(atPath: kitless.dir, withIntermediateDirectories: true)
        try "dylib".write(toFile: "\(kitless.dir)/SimlessRuntime.dylib", atomically: true, encoding: .utf8)
        XCTAssertTrue(RuntimeHost.keepsInjectedRuntime(kitless, current: "/r/y"), "a copy of no known build")
        try RuntimeHost.recordInjected(kitless, build: "/r/x")
        XCTAssertTrue(RuntimeHost.keepsInjectedRuntime(kitless, current: "/r/y"))
        XCTAssertFalse(RuntimeHost.keepsInjectedRuntime(kitless, current: "/r/x"))
        XCTAssertFalse(RuntimeHost.keepsInjectedRuntime(slot(builtWithKit: true), current: "/r/y"))
    }

    /// A patch for the running host compiles only against the runtime it injects.
    func testAPatchRefusesToCompileAgainstAnotherRuntime() throws {
        let kitless = slot(builtWithKit: false)
        try FileManager.default.createDirectory(atPath: kitless.dir, withIntermediateDirectories: true)
        try RuntimeHost.recordInjected(kitless, build: "/r/not-current")
        XCTAssertThrowsError(try RuntimeHost.injectedModule(kitless, current: "/r/current")) { error in
            XCTAssertTrue("\(error)".contains("SimlessRuntime changed"), "\(error)")
        }
    }
}
