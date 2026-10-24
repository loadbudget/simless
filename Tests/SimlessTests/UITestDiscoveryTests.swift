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
        \t\t\t);
        \t\t\tpath = Apps;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tG10000000000000000000003 /* AppUITests */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tF1000000000000000000000A /* AppUITests.swift */,
        \t\t\t\tF1000000000000000000000D /* Data.json */,
        \t\t\t);
        \t\t\tpath = AppUITests;
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tS10000000000000000000000 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t\tB1000000000000000000000A /* AppUITests.swift in Sources */,
        \t\t\t\tB1000000000000000000000B /* Shared.swift in Sources */,
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
        XCTAssertEqual(PBX.sourceFiles(target: "AppUITests", pbx: pbx), ["ios-app/Apps/AppUITests/AppUITests.swift", "Shared/Shared.swift"])
        XCTAssertEqual(PBX.sourceFiles(target: "Other", pbx: pbx), [])
        XCTAssertEqual(PBX.synchronizedFolders(target: "AppUITests", pbx: pbx), [])
    }

    /// The files of the build phase are the target's sources; no folder named
    /// like the target is needed.
    func testATargetInAClassicGroupFindsItsSources() {
        let sources = UITestEngine.sourceFiles(target: "AppUITests", pbx: pbx, projectDir: "/repo", root: "/repo", uiSources: nil)
        XCTAssertEqual(sources, ["/repo/Shared/Shared.swift", "/repo/ios-app/Apps/AppUITests/AppUITests.swift"])
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
