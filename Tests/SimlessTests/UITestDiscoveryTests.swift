// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Which files a UI test target compiles, and which tests they declare.
final class UITestDiscoveryTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func target(_ files: [String: String]) throws -> UITestEngine.UITarget {
        let paths = try files.keys.sorted().map { name -> String in
            let path = "\(dir!)/\(name)"
            try files[name]!.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        return UITestEngine.UITarget(name: "AppUITests", sources: paths)
    }

    private func ids(_ files: [String: String]) throws -> [String] {
        UITestEngine.tests(in: try target(files)).map { "\($0.cls)/\($0.method)" }
    }

    /// A base class in one file, its subclasses in others, and most tests in
    /// extensions of a subclass, spread over more files.
    func testTestsInSubclassesAndExtensionsAcrossFiles() throws {
        let found = try ids([
            "A-Base.swift": """
                import XCTest

                @MainActor
                class UITestCase: XCTestCase {
                    func launch() {}
                }
                """,
            "B-AppUITests.swift": """
                import XCTest

                final class AppUITests: UITestCase {
                    func testFirst() throws {}
                    func helper() {}
                }
                """,
            "C-More.swift": """
                import XCTest

                extension AppUITests {
                    func testSecond() async throws {}

                    @MainActor
                    func testThird() async throws {}
                }
                """,
            "D-Seeded.swift": """
                import XCTest

                @MainActor final class SeededUITests: UITestCase {
                    func testSeeded() async throws {}
                }

                private struct Export: Decodable {
                    func testNotATest() {}
                }
                """,
        ])
        XCTAssertEqual(found, ["AppUITests/testFirst", "AppUITests/testSecond", "AppUITests/testThird", "SeededUITests/testSeeded"])
    }

    /// XCTest runs a superclass's tests in each subclass too, at any depth.
    func testInheritedTestsRunInEachSubclass() throws {
        let found = try ids([
            "A.swift": """
                open class Root: XCTest.XCTestCase {
                    func testRoot() {}
                }
                class Middle: Root {}
                """,
            "B.swift": """
                public final class Leaf: Middle {
                    func testLeaf() {}
                }
                extension Middle {
                    func testMiddle() {}
                }
                """,
        ])
        XCTAssertEqual(found.sorted(), ["Leaf/testLeaf", "Leaf/testMiddle", "Leaf/testRoot", "Middle/testMiddle", "Middle/testRoot", "Root/testRoot"])
    }

    /// A class whose chain doesn't reach XCTestCase, and extensions of types
    /// that aren't test classes of the target, yield no tests.
    func testNoTestsOutsideTestClasses() throws {
        let found = try ids([
            "A.swift": """
                import XCTest

                class UITestCase: XCTestCase {}
                class Helper: NSObject {
                    func testHelper() {}
                }
                extension XCUIApplication {
                    func testLaunch() {}
                }
                extension XCTestCase {
                    func testEverywhere() {}
                }
                """,
        ])
        XCTAssertEqual(found, [])
    }

    /// A top-level declaration after a test class ends it.
    func testTopLevelDeclarationEndsTheClass() throws {
        let found = try ids([
            "A.swift": """
                final class AppUITests: XCTestCase {
                    func testOne() {}
                }
                private enum Steps {
                    static func run() {}
                    func testStep() {}
                }
                fileprivate func helper() {
                    func testInner() {}
                }
                """,
        ])
        XCTAssertEqual(found, ["AppUITests/testOne"])
    }

    /// Modifiers and attributes that XCTest runs a test with.
    func testModifiersAndAttributesOfATestMethod() throws {
        let found = try ids([
            "A.swift": """
                class Base: XCTestCase {}
                final class AppUITests: Base
                {
                    final func testFinal() {}
                    public func testPublic() {}
                    nonisolated func testNonisolated() {}
                    override func testOverride() {}
                    @available(iOS 17, *) func testAvailable() {}
                    @MainActor @objc dynamic func testObjc() async throws {}
                }
                """,
        ])
        XCTAssertEqual(found, ["AppUITests/testFinal", "AppUITests/testPublic", "AppUITests/testNonisolated", "AppUITests/testOverride",
                               "AppUITests/testAvailable", "AppUITests/testObjc"])
    }

    /// Methods that XCTest doesn't run: with a result, in a block comment, in
    /// a nested type, private, or in a private extension.
    func testMethodsThatXCTestDoesNotRun() throws {
        let found = try ids([
            "A.swift": """
                final class AppUITests: XCTestCase {
                    func testReturns() -> Int { 1 }
                    /*
                    func testCommented() {}
                    */
                    let brace = "{ /* "
                    struct Page {
                        func testable() {}
                    }
                    private func testPrivate() {}
                    func testKept() throws {}
                }
                private extension AppUITests {
                    func testPrivateExtension() {}
                }
                fileprivate extension AppUITests {
                    func testFileprivateExtension() {}
                }
                """,
        ])
        XCTAssertEqual(found, ["AppUITests/testKept"])
    }

    /// A generic base class passes its tests on, and `#if` takes the iPhone
    /// simulator's branch, around a class or an extension.
    func testGenericBasesAndConditions() throws {
        let found = try ids([
            "A.swift": """
                class Generic<T>: XCTestCase {
                    func testGeneric() {}
                }
                final class Concrete: Generic<Int> {}
                #if os(macOS)
                extension Concrete {
                    func testMac() {}
                }
                #else
                extension Concrete {
                    func testPhone() {}
                }
                #endif
                """,
        ])
        XCTAssertEqual(found.sorted(), ["Concrete/testGeneric", "Concrete/testPhone", "Generic/testGeneric"])
    }

    /// A cycle of superclasses yields nothing; a class declared twice yields
    /// its tests once.
    func testCyclesAndClassesDeclaredTwice() throws {
        let found = try ids([
            "A.swift": """
                class A: B { func testA() {} }
                class B: A {}
                class Twice: XCTestCase {
                    func testOnce() {}
                }
                """,
            "B.swift": """
                class Twice: XCTestCase {
                    func testOnce() {}
                }
                """,
        ])
        XCTAssertEqual(found, ["Twice/testOnce"])
    }

    /// A superclass that no file of the target declares (one from a package)
    /// ends the chain, and simless names it.
    func testASuperclassFromOutsideTheTargetIsNamed() throws {
        let t = try target([
            "A.swift": """
                import TestSupport
                final class AppUITests: UITestCase {
                    func testOne() {}
                }
                class Helper: NSObject {
                    func testNothing() {}
                }
                """,
        ])
        let found = UITestEngine.discover(t)
        XCTAssertEqual(found.tests, [])
        XCTAssertEqual(found.unknownSuperclasses.map { "\($0.cls): \($0.superclass)" }, ["AppUITests: UITestCase"])
        let message = UITestEngine.noTestsMessage([t])
        XCTAssertTrue(message.contains("found no test methods in AppUITests (1 Swift file(s))"), message)
        XCTAssertTrue(message.contains("AppUITests inherits from UITestCase, which no file of AppUITests declares"), message)
    }

    /// A UI test target in a classic group: Xcode lists each file in the
    /// target's Sources build phase, with paths relative to the groups.
    let pbx = """
        // !$*UTF8*$!
        {
        \tobjects = {
        \t\tB1000000000000000000000A /* AppUITests.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000A /* AppUITests.swift */; };
        \t\tB1000000000000000000000B /* Shared.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000B /* Shared.swift */; };
        \t\tB1000000000000000000000C /* Support in Frameworks */ = {isa = PBXBuildFile; productRef = P1000000000000000000000C /* Support */; };
        \t\tB1000000000000000000000D /* Data.json in Resources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000D /* Data.json */; };
        \t\tB1000000000000000000000E /* AccessibilityID.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000E /* AccessibilityID.swift */; };
        \t\tB1000000000000000000000F /* AccessibilityID.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000E /* AccessibilityID.swift */; };
        \t\tB10000000000000000000010 /* Helpers.swift in Sources */ = {isa = PBXBuildFile; fileRef = F10000000000000000000010 /* Helpers.swift */; };
        \t\tB10000000000000000000011 /* Generated.swift in Sources */ = {isa = PBXBuildFile; fileRef = F10000000000000000000011 /* Generated.swift */; };
        \t\tB10000000000000000000012 /* Localizable.strings in Sources */ = {isa = PBXBuildFile; fileRef = V10000000000000000000012 /* Localizable.strings */; };
        \t\tF1000000000000000000000E /* AccessibilityID.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AccessibilityID.swift; sourceTree = "<group>"; };
        \t\tF10000000000000000000010 /* Helpers.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = /Users/me/Shared/Helpers.swift; sourceTree = "<absolute>"; };
        \t\tF10000000000000000000011 /* Generated.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Generated.swift; sourceTree = DERIVED_FILE_DIR; };
        \t\tY10000000000000000000000 /* Synced */ = {isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {}; explicitFolders = (); path = Synced; sourceTree = "<group>"; };
        \t\tV10000000000000000000012 /* Localizable.strings */ = {
        \t\t\tisa = PBXVariantGroup;
        \t\t\tchildren = (
        \t\t\t);
        \t\t\tname = Localizable.strings;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tF1000000000000000000000A /* AppUITests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppUITests.swift; sourceTree = "<group>"; };
        \t\tF1000000000000000000000B /* Shared.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = Shared.swift; path = "Shared/Shared.swift"; sourceTree = SOURCE_ROOT; };
        \t\tF1000000000000000000000D /* Data.json */ = {isa = PBXFileReference; lastKnownFileType = text.json; path = Data.json; sourceTree = "<group>"; };
        \t\tG10000000000000000000000 = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tG10000000000000000000001 /* ios-app */,
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tG10000000000000000000001 /* ios-app */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tG10000000000000000000002 /* Apps */,
        \t\t\t);
        \t\t\tpath = "ios-app";
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tG10000000000000000000002 /* Apps */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tG10000000000000000000003 /* AppUITests */,
        \t\t\t\tG10000000000000000000004 /* App */,
        \t\t\t);
        \t\t\tpath = Apps;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tG10000000000000000000003 /* AppUITests */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tF1000000000000000000000A /* AppUITests.swift */,
        \t\t\t\tF1000000000000000000000D /* Data.json */,
        \t\t\t\tV10000000000000000000012 /* Localizable.strings */,
        \t\t\t);
        \t\t\tpath = AppUITests;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tG10000000000000000000004 /* App */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tF1000000000000000000000E /* AccessibilityID.swift */,
        \t\t\t);
        \t\t\tpath = App;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tS10000000000000000000003 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tfiles = (
        \t\t\t\tB1000000000000000000000E /* AccessibilityID.swift in Sources */,
        \t\t\t);
        \t\t};
        \t\tT10000000000000000000001 /* App */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \t\t\t\tS10000000000000000000003 /* Sources */,
        \t\t\t);
        \t\t\tfileSystemSynchronizedGroups = (
        \t\t\t\tY10000000000000000000000 /* Synced */,
        \t\t\t);
        \t\t\tname = App;
        \t\t\tproductType = "com.apple.product-type.application";
        \t\t};
        \t\tS10000000000000000000000 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t\tB1000000000000000000000A /* AppUITests.swift in Sources */,
        \t\t\t\tB1000000000000000000000B /* Shared.swift in Sources */,
        \t\t\t\tB1000000000000000000000F /* AccessibilityID.swift in Sources */,
        \t\t\t\tB10000000000000000000010 /* Helpers.swift in Sources */,
        \t\t\t\tB10000000000000000000011 /* Generated.swift in Sources */,
        \t\t\t\tB10000000000000000000012 /* Localizable.strings in Sources */,
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};
        \t\tS10000000000000000000001 /* Frameworks */ = {
        \t\t\tisa = PBXFrameworksBuildPhase;
        \t\t\tfiles = (
        \t\t\t\tB1000000000000000000000C /* Support in Frameworks */,
        \t\t\t);
        \t\t};
        \t\tS10000000000000000000002 /* Resources */ = {
        \t\t\tisa = PBXResourcesBuildPhase;
        \t\t\tfiles = (
        \t\t\t\tB1000000000000000000000D /* Data.json in Resources */,
        \t\t\t);
        \t\t};
        \t\tT10000000000000000000000 /* AppUITests */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \t\t\t\tS10000000000000000000000 /* Sources */,
        \t\t\t\tS10000000000000000000002 /* Resources */,
        \t\t\t\tS10000000000000000000001 /* Frameworks */,
        \t\t\t);
        \t\t\tname = AppUITests;
        \t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
        \t\t};
        \t};
        }
        """

    func testSourcesBuildPhaseFilesResolveThroughGroups() {
        XCTAssertEqual(PBX.sourceFiles(target: "AppUITests", pbx: pbx),
                       ["ios-app/Apps/AppUITests/AppUITests.swift", "Shared/Shared.swift", "ios-app/Apps/App/AccessibilityID.swift",
                        "/Users/me/Shared/Helpers.swift", "ios-app/Apps/AppUITests"])
        XCTAssertEqual(PBX.unresolvedSwiftFiles(target: "AppUITests", pbx: pbx).map { "\($0.name) \($0.sourceTree)" }, ["Generated.swift DERIVED_FILE_DIR"])
        XCTAssertEqual(PBX.sourceFiles(target: "App", pbx: pbx), ["ios-app/Apps/App/AccessibilityID.swift"])
        XCTAssertEqual(PBX.sourceFiles(target: "Other", pbx: pbx), [])
        XCTAssertEqual(PBX.synchronizedFolders(target: "AppUITests", pbx: pbx), [])
        XCTAssertEqual(PBX.targetNames(pbx: pbx), ["App", "AppUITests"])
    }

    /// `projectDirPath` moves `SOURCE_ROOT` and the main group.
    func testProjectDirPathIsWhereSourceRootStarts() {
        let moved = """
            \t\tB1000000000000000000000A /* A.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000A /* A.swift */; };
            \t\tB1000000000000000000000B /* B.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1000000000000000000000B /* B.swift */; };
            \t\tF1000000000000000000000A /* A.swift */ = {isa = PBXFileReference; path = A.swift; sourceTree = SOURCE_ROOT; };
            \t\tF1000000000000000000000B /* B.swift */ = {isa = PBXFileReference; path = B.swift; sourceTree = "<group>"; };
            \t\tR10000000000000000000000 /* Project object */ = {
            \t\t\tisa = PBXProject;
            \t\t\tprojectDirPath = Sub;
            \t\t};
            \t\tS10000000000000000000000 /* Sources */ = {
            \t\t\tisa = PBXSourcesBuildPhase;
            \t\t\tfiles = (
            \t\t\t\tB1000000000000000000000A /* A.swift in Sources */,
            \t\t\t\tB1000000000000000000000B /* B.swift in Sources */,
            \t\t\t);
            \t\t};
            \t\tT10000000000000000000000 /* T */ = {
            \t\t\tisa = PBXNativeTarget;
            \t\t\tbuildPhases = (
            \t\t\t\tS10000000000000000000000 /* Sources */,
            \t\t\t);
            \t\t\tname = T;
            \t\t};
            """
        XCTAssertEqual(PBX.sourceFiles(target: "T", pbx: moved), ["Sub/A.swift", "Sub/B.swift"])
    }

    /// The files of the build phase are the target's sources, and the folder
    /// named like the target is then not read.
    func testATargetInAClassicGroupFindsItsSources() throws {
        try FileManager.default.createDirectory(atPath: "\(dir!)/AppUITests", withIntermediateDirectories: true)
        try "".write(toFile: "\(dir!)/AppUITests/Extra.swift", atomically: true, encoding: .utf8)
        let sources = UITestEngine.sourceFiles(target: "AppUITests", pbx: pbx, projectDir: dir, root: dir, uiSources: nil)
        XCTAssertEqual(sources, ["/Users/me/Shared/Helpers.swift", "\(dir!)/Shared/Shared.swift",
                                 "\(dir!)/ios-app/Apps/App/AccessibilityID.swift", "\(dir!)/ios-app/Apps/AppUITests/AppUITests.swift"])
    }

    /// tests.uiSources adds its folder to the listed files, and a file that
    /// both give, through a path with a trailing slash, is compiled once.
    func testUISourcesFolderAndListedFilesUniteOnce() throws {
        let folder = "\(dir!)/ios-app/Apps/AppUITests"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "".write(toFile: "\(folder)/AppUITests.swift", atomically: true, encoding: .utf8)
        try "".write(toFile: "\(folder)/More.swift", atomically: true, encoding: .utf8)
        let sources = UITestEngine.sourceFiles(target: "AppUITests", pbx: pbx, projectDir: dir, root: dir, uiSources: "ios-app/Apps/AppUITests/")
        XCTAssertEqual(sources.filter { $0.hasPrefix(folder) }, ["\(folder)/AppUITests.swift", "\(folder)/More.swift"])
    }

    /// A UI test source leaves the record of the app's build only when no
    /// other target compiles it, by its Sources build phase or a synchronized folder.
    func testAFileTheAppCompilesStaysInTheBuildRecord() {
        let ui = ["/repo/ios-app/Apps/AppUITests/AppUITests.swift", "/repo/ios-app/Apps/App/AccessibilityID.swift",
                  "/repo/Synced/Shared.swift", "/repo/Shared/Shared.swift", "/repo/SyncedOther/X.swift"]
        XCTAssertEqual(UITestEngine.uiOnly(ui, pbx: pbx, projectDir: "/repo"),
                       ["/repo/ios-app/Apps/AppUITests/AppUITests.swift", "/repo/Shared/Shared.swift", "/repo/SyncedOther/X.swift"])
    }

    /// The error names each target, and the fix that fits it.
    func testMissingSourcesReasons() {
        XCTAssertEqual(UITestEngine.missingSourcesReason(target: "AppUITests", pbx: "", project: "App.xcodeproj", projectDir: "/repo", uiSources: "UITests"),
                       "AppUITests: tests.uiSources names UITests, which holds no Swift file")
        let none = UITestEngine.missingSourcesReason(target: "AppUITests", pbx: "", project: "App.xcodeproj", projectDir: "/repo", uiSources: nil)
        XCTAssertTrue(none.hasPrefix("AppUITests: no synchronized folder, no Swift file in its Sources build phase in App.xcodeproj, and no folder /repo/AppUITests; set tests.uiSources"), none)
        let synced = UITestEngine.missingSourcesReason(target: "App", pbx: pbx, project: "App.xcodeproj", projectDir: "/repo", uiSources: nil)
        XCTAssertTrue(synced.hasPrefix("App: no Swift file in its synchronized folders (Synced) or its Sources build phase in App.xcodeproj; set"), synced)
    }
    /// With no synchronized folder and no listed file, the folder named like
    /// the target, then tests.uiSources.
    func testFolderLookupsWhenTheProjectListsNoFiles() throws {
        try FileManager.default.createDirectory(atPath: "\(dir!)/AppUITests/Sub", withIntermediateDirectories: true)
        try "".write(toFile: "\(dir!)/AppUITests/Sub/A.swift", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(dir!)/Elsewhere", withIntermediateDirectories: true)
        try "".write(toFile: "\(dir!)/Elsewhere/B.swift", atomically: true, encoding: .utf8)
        XCTAssertEqual(UITestEngine.sourceFiles(target: "AppUITests", pbx: "", projectDir: dir, root: dir, uiSources: nil),
                       ["\(dir!)/AppUITests/Sub/A.swift"])
        XCTAssertEqual(UITestEngine.sourceFiles(target: "AppUITests", pbx: "", projectDir: dir, root: dir, uiSources: "Elsewhere"),
                       ["\(dir!)/Elsewhere/B.swift"])
    }
}
