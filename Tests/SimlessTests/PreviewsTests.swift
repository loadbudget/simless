// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Fixtures from #Preview blocks and the App, generated from source.
final class PreviewsTests: XCTestCase {
    let app = """
        import SwiftUI

        @main
        struct NotesApp: App {
            @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
            @StateObject private var settings = AppSettings()

            init() {
                Analytics.start()
            }

            var body: some Scene {
                WindowGroup {
                    ContentView()
                        .environmentObject(settings)
                }
                .modelContainer(for: Note.self)
                .commands { CommandGroup(replacing: .newItem) {} }
            }
        }
        """

    let row = """
        import SwiftUI

        struct NoteRow: View {
            let note: Note
            var body: some View { Text(note.title) }
        }

        private let sample = Note(title: "Groceries")

        #Preview("Short") {
            NoteRow(note: sample)
        }

        #Preview {
            @Previewable @State var on = true
            Toggle("On", isOn: $on)
        }

        #Preview(as: .systemSmall) {
            NotesWidget()
        } timeline: {
            Entry()
        }

        struct NoteRow_Previews: PreviewProvider {
            static var previews: some View { NoteRow(note: sample) }
        }
        """

    func input() -> PatchScope.Input {
        var i = PatchScope.Input()
        i.sources = ["NotesApp.swift": app, "NoteRow.swift": row]
        return i
    }

    func testNamesAndWhatsLeftOut() throws {
        let g = Previews.generate(input(), skip: [:])
        XCTAssertEqual(g.entries.map(\.name), ["root", "NoteRow.Short", "NoteRow.2", "NoteRow.3", "NoteRow.NoteRow_Previews"])
        XCTAssertEqual(g.entries.first { $0.name == "NoteRow.3" }?.skipped, "a widget or Live Activity preview, not a view")
        XCTAssertEqual(g.calls.count, 4)
    }

    func testCopiesKeepTheirLinesAndPrivateHelpers() throws {
        let g = Previews.generate(input(), skip: [:])
        for (file, text) in [("NotesApp.swift", app), ("NoteRow.swift", row)] {
            let copy = try XCTUnwrap(g.texts[file])
            XCTAssertEqual(copy.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count, file)
        }
        let copy = g.texts["NoteRow.swift"]!
        XCTAssertTrue(copy.contains("private let sample = Note(title: \"Groceries\")"))
        XCTAssertFalse(copy.contains("struct NoteRow: View"))   // the app's own
        XCTAssertTrue(copy.contains("r.add(\"NoteRow.Short\") { simlessPreviewContent {"))
        XCTAssertTrue(copy.contains("@State var on = true"))
        XCTAssertFalse(copy.contains("@Previewable"))
        XCTAssertTrue(copy.contains("{ NoteRow_Previews.previews }"))
        XCTAssertFalse(copy.contains("#Preview"))
    }

    func testRootIsTheAppAsAView() throws {
        let copy = try XCTUnwrap(Previews.generate(input(), skip: [:]).texts["NotesApp.swift"])
        XCTAssertTrue(copy.contains("struct SimlessRootView1: View {"))
        XCTAssertFalse(copy.contains("@main"))
        XCTAssertTrue(copy.contains("var appDelegate: AppDelegate { simlessAppDelegate(AppDelegate.self) }"))
        XCTAssertTrue(copy.contains("@StateObject private var settings = AppSettings()"))
        XCTAssertFalse(copy.contains("Analytics.start()"))       // the App's init runs once, in the app
        XCTAssertTrue(copy.contains(".modelContainer(for: Note.self)"))
        XCTAssertFalse(copy.contains(".commands"))               // a scene-only modifier
        XCTAssertTrue(copy.contains("r.add(\"root\") { SimlessRootView1() }"))
    }

    func testSkippedPreviewsAreLeftOutWithTheReason() throws {
        let g = Previews.generate(input(), skip: [.init(file: "NoteRow.swift", name: "NoteRow.Short"): "doesn't compile"])
        XCTAssertEqual(g.entries.first { $0.name == "NoteRow.Short" }?.skipped, "doesn't compile")
        XCTAssertFalse(g.texts["NoteRow.swift"]!.contains("NoteRow.Short"))
    }

    func testAFailedRoundLeavesOutThePreviewAndCompilesAgain() throws {
        var compiled = 0
        let m = try Previews.compileLeavingOut(input()) { _, _ in
            compiled += 1
            if compiled == 1 { throw SimlessError("patch compile failed\nNoteRow.swift:11:5: error: cannot find 'sample' in scope") }
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(compiled, 2)
        XCTAssertEqual(m.dylib, "/tmp/previews.dylib")
        XCTAssertEqual(m.entries.first { $0.name == "NoteRow.Short" }?.skipped,
                       "doesn't compile outside Xcode's previews: cannot find 'sample' in scope")
    }

    func testPreviewsThatStillFailAfterTheLastRoundKeepTheReasons() throws {
        let lines = [11, 16]
        var compiled = 0
        let m = try Previews.compileLeavingOut(input(), rounds: 2) { _, _ in
            defer { compiled += 1 }
            throw SimlessError("patch compile failed\nNoteRow.swift:\(lines[compiled]):5: error: no such module 'WatchKit'")
        }
        XCTAssertEqual(compiled, 2)
        XCTAssertNil(m.dylib)
        XCTAssertEqual(m.failure, "previews still don't compile after 2 rounds (2 left out for compile errors); NoteRow.swift:16:5: error: no such module 'WatchKit'")
        XCTAssertEqual(m.entries.first { $0.name == "NoteRow.2" }?.skipped,
                       "doesn't compile outside Xcode's previews: no such module 'WatchKit'")
        XCTAssertNotNil(m.entries.first { $0.skipped == nil })
    }

    func testALastRoundThatLeavesOutEveryPreviewIsNoFailure() throws {
        // An error outside every preview leaves out all of its file's previews.
        let errors = ["NoteRow.swift:1:1", "NotesApp.swift:1:1"]
        var compiled = 0
        let m = try Previews.compileLeavingOut(input(), rounds: errors.count) { _, _ in
            defer { compiled += 1 }
            throw SimlessError("patch compile failed\n\(errors[compiled]): error: no such module 'WatchKit'")
        }
        XCTAssertNil(m.failure)
        XCTAssertTrue(m.entries.allSatisfy { $0.skipped != nil })
    }

    let watchApp = """
        import SwiftUI
        import WatchKit

        @main
        struct NotesWatchApp: App {
            var body: some Scene {
                WindowGroup { WatchView() }
            }
        }
        """

    /// The iOS app and a watchOS app in another folder, each with a `Short` preview.
    func twoApps(watchFirst: Bool = false) -> PatchScope.Input {
        var i = PatchScope.Input()
        let (ios, watch) = watchFirst ? ("/w/B", "/w/A") : ("/w/App", "/w/Watch")
        i.sources = ["\(ios)/NotesApp.swift": app, "\(ios)/NoteRow.swift": row,
                     "\(watch)/NotesWatchApp.swift": watchApp, "\(watch)/WatchRow.swift": "import SwiftUI\n\n#Preview(\"Short\") {\n    WatchRow()\n}\n"]
        return i
    }

    let twoAppsNames = ["NotesApp.root", "NotesWatchApp.root", "NoteRow.Short", "NoteRow.2", "NoteRow.3", "NoteRow.NoteRow_Previews", "WatchRow.Short"]

    func testANameTwoEntriesShareTakesEachOnesFileName() throws {
        let g = Previews.generate(twoApps(), skip: [:])
        XCTAssertEqual(g.entries.map(\.name), twoAppsNames)
        XCTAssertEqual(g.entries.map(\.file), ["/w/App/NotesApp.swift", "/w/Watch/NotesWatchApp.swift"] + Array(repeating: "/w/App/NoteRow.swift", count: 4) + ["/w/Watch/WatchRow.swift"])
        XCTAssertTrue(g.texts["/w/App/NotesApp.swift"]!.contains("r.add(\"NotesApp.root\") { SimlessRootView1() }"))
        XCTAssertTrue(g.texts["/w/Watch/NotesWatchApp.swift"]!.contains("r.add(\"NotesWatchApp.root\") { SimlessRootView2() }"))
        XCTAssertEqual(g.entries.map { $0.app == true }, [true, true, false, false, false, false, false])
    }

    func testAnAppThatFailsLeavesOutOnlyItsOwnRoot() throws {
        var compiled = 0
        let m = try Previews.compileLeavingOut(twoApps()) { gen, _ in
            compiled += 1
            if compiled == 1 { throw SimlessError("patch compile failed\n/w/Watch/NotesWatchApp.swift:2:8: error: no such module 'WatchKit'") }
            XCTAssertTrue(gen.texts["/w/App/NotesApp.swift"]!.contains("r.add(\"NotesApp.root\")"))
            XCTAssertNil(gen.texts["/w/Watch/NotesWatchApp.swift"])
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(compiled, 2)
        XCTAssertEqual(m.entries.map(\.name), twoAppsNames)   // the same as when both compile
        XCTAssertEqual(m.entries.filter { $0.name.hasSuffix(".root") }.map(\.skipped),
                       [nil, "doesn't compile outside Xcode's previews: no such module 'WatchKit'"])
        XCTAssertEqual(Previews.summary(m, root: "/w", manifestPath: "/w/previews.json"),
                       "previews: 5 of 7 generated; left out: NotesWatchApp.root (doesn't compile outside Xcode's previews: no such module 'WatchKit'); NoteRow.3 (a widget or Live Activity preview, not a view)")
    }

    func testNamesStayWhenTheAppBeforeFails() throws {
        var rounds: [[String]] = []
        let m = try Previews.compileLeavingOut(twoApps(watchFirst: true)) { gen, _ in
            rounds.append(gen.entries.map(\.name))
            if rounds.count == 1 { throw SimlessError("patch compile failed\n/w/A/NotesWatchApp.swift:2:8: error: no such module 'WatchKit'") }
            return "/tmp/previews.dylib"
        }
        let names = ["NotesWatchApp.root", "NotesApp.root", "WatchRow.Short", "NoteRow.Short", "NoteRow.2", "NoteRow.3", "NoteRow.NoteRow_Previews"]
        XCTAssertEqual(rounds, [names, names])
        XCTAssertEqual(m.entries.prefix(2).map { $0.skipped == nil }, [false, true])
    }

    func testAPreviewThatFailsLeavesOutNothingOfAnotherFile() throws {
        var compiled = 0
        let m = try Previews.compileLeavingOut(twoApps()) { gen, _ in
            compiled += 1
            if compiled == 1 { throw SimlessError("patch compile failed\n/w/App/NoteRow.swift:11:5: error: cannot find 'sample' in scope") }
            XCTAssertTrue(gen.texts["/w/Watch/WatchRow.swift"]!.contains("r.add(\"WatchRow.Short\")"))
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(compiled, 2)
        XCTAssertEqual(m.entries.first { $0.name == "NoteRow.Short" }?.skipped, "doesn't compile outside Xcode's previews: cannot find 'sample' in scope")
        XCTAssertNil(m.entries.first { $0.name == "WatchRow.Short" }?.skipped)
    }

    let shortPreview = "import SwiftUI\n\n#Preview(\"Short\") {\n    WatchRow()\n}\n"

    func testOneFileNameInTwoFoldersTakesEachOnesFolder() throws {
        var i = PatchScope.Input()
        i.sources = ["/w/App/NoteRow.swift": row, "/w/Watch/NoteRow.swift": shortPreview]
        var compiled = 0
        let m = try Previews.compileLeavingOut(i) { _, _ in
            compiled += 1
            if compiled == 1 { throw SimlessError("patch compile failed\n/w/Watch/NoteRow.swift:4:5: error: cannot find 'WatchRow' in scope") }
            return "/tmp/previews.dylib"
        }
        XCTAssertEqual(m.entries.map(\.name), ["App.NoteRow.Short", "NoteRow.2", "NoteRow.3", "NoteRow.NoteRow_Previews", "Watch.NoteRow.Short"])
        XCTAssertEqual(m.entries.first { $0.name == "App.NoteRow.Short" }?.skipped, nil)
        XCTAssertEqual(m.entries.first { $0.name == "Watch.NoteRow.Short" }?.skipped, "doesn't compile outside Xcode's previews: cannot find 'WatchRow' in scope")
    }

    func testPreviewsOfOneNameInOneFileAreNumbered() {
        var i = PatchScope.Input()
        i.sources = ["/w/App/NoteRow.swift": shortPreview + "\n#Preview(\"Short\") {\n    NoteRow()\n}\n"]
        let g = Previews.generate(i, skip: [:])
        XCTAssertEqual(g.entries.map(\.name), ["NoteRow.Short", "NoteRow.Short.2"])
        XCTAssertTrue(g.clashes.isEmpty)
    }

    func testOneFolderAndFileNameInTwoPlacesIsRefused() throws {
        var i = PatchScope.Input()
        i.root = "/w"
        i.sources = ["/w/a/Views/NoteRow.swift": row, "/w/b/Views/NoteRow.swift": shortPreview]
        XCTAssertEqual(Previews.generate(i, skip: [:]).clashes.map(\.description),
                       ["a/Views/NoteRow.swift and b/Views/NoteRow.swift both have a preview named NoteRow.Short; rename one preview, or one of their folders (their fixtures would both be Views.NoteRow.Short)"])
        XCTAssertThrowsError(try Previews.compileLeavingOut(i) { _, _ in "/tmp/previews.dylib" })
    }

    func testTwoAppsInFilesOfOneNameAreRefused() {
        var i = PatchScope.Input()
        i.root = "/w"
        i.sources = ["/w/App/Main.swift": app, "/w/Watch/Main.swift": watchApp]
        XCTAssertEqual(Previews.generate(i, skip: [:]).clashes.map(\.description),
                       ["App/Main.swift and Watch/Main.swift each have an @main App; rename one of the files (their fixtures would both be Main.root)"])
    }

    func testARenamedRootThatMeetsAPreviewNameIsRefused() {
        var i = twoApps()
        i.root = "/w"
        i.sources["/w/App/NotesApp.swift"] = app + "\n\n#Preview(\"root\") {\n    ContentView()\n}\n"
        XCTAssertEqual(Previews.generate(i, skip: [:]).clashes.map(\.description),
                       ["App/NotesApp.swift and App/NotesApp.swift both give a fixture named NotesApp.root; rename the preview in App/NotesApp.swift"])
    }

    func testALocalPackagesPreviewTakesNoPartInNames() {
        var i = PatchScope.Input()
        i.sources = ["/w/App/ContentView.swift": shortPreview, "/w/Core/ContentView.swift": shortPreview]
        i.moduleOf = ["/w/Core/ContentView.swift": "Core"]
        let g = Previews.generate(i, skip: [:])
        XCTAssertEqual(g.entries.map(\.name), ["ContentView.Short", "ContentView.Short"])
        XCTAssertTrue(g.clashes.isEmpty)
        XCTAssertEqual(g.entries.map { $0.skipped == nil }, [true, false])
        XCTAssertEqual(Previews.summary(.init(dylib: "/tmp/previews.dylib", entries: g.entries), root: "/w", manifestPath: "/w/previews.json"),
                       "previews: 1 of 2 generated; left out: ContentView.Short in Core/ContentView.swift (it's in a local package; only the app target's previews are generated)")
    }

    func testAPatchCompilesWhatItAsksForAsTheBuildNamedIt() throws {
        let m = try Previews.compileLeavingOut(twoApps()) { _, _ in "/tmp/previews.dylib" }
        var manifest = m
        let watch = manifest.entries.firstIndex { $0.name == "NotesWatchApp.root" }!
        manifest.entries[watch].skipped = "doesn't compile outside Xcode's previews: no such module 'WatchKit'"
        let p = try Previews.patchCode(twoApps(), manifest: manifest, names: ["NotesApp.root", "NotesWatchApp.root"], kept: [:], texts: [:])
        XCTAssertTrue(p.texts["/w/App/NotesApp.swift"]!.contains("r.add(\"NotesApp.root\")"))
        XCTAssertNil(p.texts["/w/Watch/NotesWatchApp.swift"])
    }

    func testAPatchIgnoresAClashItDoesntAskFor() throws {
        var i = twoApps()
        i.sources["/w/x/Views/Card.swift"] = shortPreview
        i.sources["/w/y/Views/Card.swift"] = shortPreview
        XCTAssertFalse(Previews.generate(i, skip: [:]).clashes.isEmpty)
        let p = try Previews.patchCode(i, manifest: nil, names: ["WatchRow.Short"], kept: [:], texts: [:])
        XCTAssertTrue(p.texts["/w/Watch/WatchRow.swift"]!.contains("r.add(\"WatchRow.Short\")"))
        XCTAssertThrowsError(try Previews.patchCode(i, manifest: nil, names: ["Views.Card.Short"], kept: [:], texts: [:]))
    }

    func testAPatchForANameTheSourcesNoLongerGiveSaysToRunUp() {
        XCTAssertThrowsError(try Previews.patchCode(twoApps(), manifest: nil, names: ["root"], kept: [:], texts: [:])) { error in
            XCTAssertEqual("\(error)", "root isn't a preview of the current sources (the names changed since simless up); run simless up")
        }
    }

    func testCheckNamesReadsTheWorktreeWithoutABuild() throws {
        let root = NSTemporaryDirectory() + "simless-names-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(root)/Src/App", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/Src/Watch", withIntermediateDirectories: true)
        try """
            {"project": "App.xcodeproj", "scheme": "App", "appTarget": "App", "testTarget": "", "sourceDirs": ["Src"], "device": "iphone"}
            """.write(toFile: "\(root)/.simless.json", atomically: true, encoding: .utf8)
        let ws = try Workspace.load(at: root)
        defer { try? FileManager.default.removeItem(atPath: ws.work); try? FileManager.default.removeItem(atPath: root) }
        try app.write(toFile: "\(root)/Src/App/Main.swift", atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try Previews.checkNames(ws))
        try watchApp.write(toFile: "\(root)/Src/Watch/Main.swift", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Previews.checkNames(ws)) { error in
            XCTAssertEqual("\(error)", "the fixtures can't be named: Src/App/Main.swift and Src/Watch/Main.swift each have an @main App; rename one of the files (their fixtures would both be Main.root)")
        }
    }

    func testOnlyGeneratesWhatsAsked() throws {
        let g = Previews.generate(input(), skip: [:], only: ["NoteRow.2"])
        XCTAssertEqual(g.entries.map(\.name), ["NoteRow.2"])
        XCTAssertNil(g.texts["NotesApp.swift"])
    }
}
