// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Which package products a UI test target links, where each comes from, and
/// what the bundle build gets for them.
final class UITestPackageProductsTests: XCTestCase {
    /// A project with a UI test target that links `products` (id, product name,
    /// package id or nil), a local package `Core` and a remote package.
    private func pbx(_ products: [(String, String, String?)], extra: String = "") -> String {
        let deps = products.map { "\t\t\t\t\($0.0) /* \($0.1) */," }.joined(separator: "\n")
        let objects = products.filter { $0.1 != "NoObject" }.map { id, name, package in
            "\t\t\(id) /* \(name) */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
                + (package.map { "\t\t\tpackage = \($0) /* package */;\n" } ?? "")
                + (name == "NoName" ? "" : "\t\t\tproductName = \(name);\n") + "\t\t};"
        }.joined(separator: "\n")
        return """
            // !$*UTF8*$!
            {
            \tobjects = {
            \t\tAAAAAAAAAAAAAAAAAAAAAAA1 /* AppUITests */ = {
            \t\t\tisa = PBXNativeTarget;
            \t\t\tname = AppUITests;
            \t\t\tpackageProductDependencies = (
            \(deps)
            \t\t\t);
            \t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
            \t\t};
            \t\tAAAAAAAAAAAAAAAAAAAAAAA2 /* XCLocalSwiftPackageReference "Packages/Core" */ = {
            \t\t\tisa = XCLocalSwiftPackageReference;
            \t\t\trelativePath = "Packages/Core";
            \t\t};
            \t\tAAAAAAAAAAAAAAAAAAAAAAA3 /* XCRemoteSwiftPackageReference "swift-snapshot-testing" */ = {
            \t\t\tisa = XCRemoteSwiftPackageReference;
            \t\t\trepositoryURL = "https://github.com/pointfreeco/swift-snapshot-testing";
            \t\t};
            \(objects)
            \t};
            }
            """
    }

    private static func manifest(_ name: String, _ products: [String], macOS: String? = nil, local: [String] = [], remote: [String] = []) -> PackageManifest {
        PackageManifest(name: name, products: products, macOS: macOS, localDependencies: local, remoteDependencies: remote)
    }

    private let core = manifest("Core", ["TestSupport", "Ledger"], macOS: "15.0", local: ["/repo/Packages/Core/../Shared"])
    private let other = manifest("Other", ["Charts"])
    private let shared = manifest("Shared", ["Fixtures"], remote: ["swift-algorithms"])

    private func manifests(_ dir: String) throws -> PackageManifest {
        switch dir {
        case "/repo/Packages/Core": return core
        case "/repo/Packages/Other": return other
        case "/repo/Packages/Shared": return shared
        default: throw SimlessError("no manifest at \(dir)")
        }
    }

    private func linked(_ project: String, local: [String] = ["/repo/Packages/Core", "/repo/Packages/Other"]) throws -> [UITestEngine.LinkedProduct] {
        try UITestEngine.linkedProducts(target: "AppUITests", pbx: project, projectDir: "/repo", localPackages: local, manifest: manifests)
    }

    private func error(_ body: () throws -> Any) -> String {
        do { _ = try body(); return "" } catch { return "\(error)" }
    }

    func testReadsEachKindOfPackageReference() {
        let project = pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "TestSupport", nil),
                           ("BBBBBBBBBBBBBBBBBBBBBBB2", "Ledger", "AAAAAAAAAAAAAAAAAAAAAAA2"),
                           ("BBBBBBBBBBBBBBBBBBBBBBB3", "SnapshotTesting", "AAAAAAAAAAAAAAAAAAAAAAA3"),
                           ("BBBBBBBBBBBBBBBBBBBBBBB4", "Gone", "CCCCCCCCCCCCCCCCCCCCCCC9"),
                           ("BBBBBBBBBBBBBBBBBBBBBBB5", "NoObject", nil),
                           ("BBBBBBBBBBBBBBBBBBBBBBB6", "NoName", nil)])
        XCTAssertEqual(PBX.packageProducts(target: "AppUITests", pbx: project), [
            PBX.PackageProduct(name: "TestSupport", package: .unnamed),
            PBX.PackageProduct(name: "Ledger", package: .local("Packages/Core")),
            PBX.PackageProduct(name: "SnapshotTesting", package: .remote("https://github.com/pointfreeco/swift-snapshot-testing")),
            PBX.PackageProduct(name: "Gone", package: .unknown("CCCCCCCCCCCCCCCCCCCCCCC9")),
            PBX.PackageProduct(name: "BBBBBBBBBBBBBBBBBBBBBBB5", package: .unknown("no object BBBBBBBBBBBBBBBBBBBBBBB5")),
            PBX.PackageProduct(name: "BBBBBBBBBBBBBBBBBBBBBBB6", package: .unknown("no productName in BBBBBBBBBBBBBBBBBBBBBBB6")),
        ])
        XCTAssertEqual(PBX.packageProducts(target: "OtherTarget", pbx: project), [])
    }

    func testAProductWithNoPackageComesFromTheLocalPackageThatDeclaresIt() throws {
        let found = try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Charts", nil),
                                    ("BBBBBBBBBBBBBBBBBBBBBBB2", "TestSupport", nil),
                                    ("BBBBBBBBBBBBBBBBBBBBBBB3", "Ledger", "AAAAAAAAAAAAAAAAAAAAAAA2")]))
        XCTAssertEqual(found, [
            UITestEngine.LinkedProduct(name: "Charts", packageDir: "/repo/Packages/Other", manifest: other),
            UITestEngine.LinkedProduct(name: "TestSupport", packageDir: "/repo/Packages/Core", manifest: core),
            UITestEngine.LinkedProduct(name: "Ledger", packageDir: "/repo/Packages/Core", manifest: core),
        ])
        let grouped = UITestEngine.productsByPackage(found)
        XCTAssertEqual(grouped.map(\.dir), ["/repo/Packages/Core", "/repo/Packages/Other"])
        XCTAssertEqual(grouped.map(\.products), [["TestSupport", "Ledger"], ["Charts"]])
    }

    /// A product of a package that a local package uses by `.package(path:)`,
    /// and that the project doesn't reference itself.
    func testAProductWithNoPackageComesFromAPackageThatALocalPackageUsesByPath() throws {
        XCTAssertEqual(try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Fixtures", nil)])),
                       [UITestEngine.LinkedProduct(name: "Fixtures", packageDir: "/repo/Packages/Shared", manifest: shared)])
        XCTAssertEqual(try UITestEngine.withLocalDependencies(["/repo/Packages/Core", "/repo/Packages/Shared"], manifest: manifests),
                       ["/repo/Packages/Core", "/repo/Packages/Shared"])
    }

    func testAProductOfARemotePackageStopsTheBuild() {
        let message = error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB3", "SnapshotTesting", "AAAAAAAAAAAAAAAAAAAAAAA3")])) }
        XCTAssertEqual(message, "AppUITests links the package product SnapshotTesting from the remote package "
                       + "https://github.com/pointfreeco/swift-snapshot-testing; simless builds a UI test bundle only with products of local packages")
    }

    func testAProductThatNoPackageDeclaresStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Missing", nil)])) },
                       "AppUITests links the package product Missing, which no local package declares "
                       + "(looked in /repo/Packages/Core, /repo/Packages/Other, /repo/Packages/Shared)")
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "TestSupport", nil)]), local: []) },
                       "AppUITests links the package product TestSupport, which no local package declares (the project has no local package)")
        // The named package doesn't declare it.
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Charts", "AAAAAAAAAAAAAAAAAAAAAAA2")])) },
                       "AppUITests links the package product Charts, which no local package declares (looked in /repo/Packages/Core)")
    }

    func testAPackageReferenceSimlessCantReadStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB4", "Gone", "CCCCCCCCCCCCCCCCCCCCCCC9")])) },
                       "AppUITests links the package product Gone from a package reference that simless can't read (CCCCCCCCCCCCCCCCCCCCCCC9)")
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB6", "NoName", nil)])) },
                       "AppUITests links the package product BBBBBBBBBBBBBBBBBBBBBBB6 from a package reference that simless can't read "
                       + "(no productName in BBBBBBBBBBBBBBBBBBBBBBB6)")
    }

    func testAManifestThatCantBeReadStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "TestSupport", nil)]), local: ["/repo/Broken"]) },
                       "AppUITests links the package product TestSupport, and simless can't read the package in /repo/Broken: no manifest at /repo/Broken")
    }

    func testAProductThatTwoPackagesDeclareStopsTheBuild() {
        let twice = { (dir: String) throws -> PackageManifest in Self.manifest(dir, ["Charts"]) }
        XCTAssertEqual(error {
            try UITestEngine.linkedProducts(target: "AppUITests", pbx: self.pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Charts", nil)]), projectDir: "/repo",
                                            localPackages: ["/repo/A", "/repo/B"], manifest: twice)
        }, "AppUITests links the package product Charts, which more than one local package declares (/repo/A, /repo/B)")
    }

    func testATargetWithNoPackageProductsLinksNothing() throws {
        XCTAssertEqual(try linked(pbx([])), [])
    }

    func testReadsProductsMacOSAndDependenciesFromDumpPackage() throws {
        let json = #"""
            {"name": "LoadbudgetCore",
             "platforms": [{"options": [], "platformName": "ios", "version": "18.0"},
                           {"options": [], "platformName": "macos", "version": "15.0"}],
             "products": [{"name": "LoadbudgetLedger", "targets": ["LoadbudgetLedger"], "type": {"library": ["automatic"]}},
                          {"name": "LoadbudgetTestSupport", "targets": ["LoadbudgetTestSupport"], "type": {"library": ["automatic"]}}],
             "dependencies": [{"fileSystem": [{"identity": "shared", "path": "/repo/Shared", "productFilter": null}]},
                              {"sourceControl": [{"identity": "swift-algorithms", "location": {"remote": [{"urlString": "https://github.com/apple/swift-algorithms"}]}}]},
                              {"registry": [{"identity": "acme.charts"}]}]}
            """#
        XCTAssertEqual(try Packages.manifest(json: json),
                       Self.manifest("LoadbudgetCore", ["LoadbudgetLedger", "LoadbudgetTestSupport"], macOS: "15.0",
                                     local: ["/repo/Shared"], remote: ["acme.charts", "swift-algorithms"]))
        XCTAssertEqual(try Packages.manifest(json: #"{"name": "Bare", "platforms": [], "products": []}"#), Self.manifest("Bare", []))
        XCTAssertEqual(error { try Packages.manifest(json: #"{"products": []}"#) }, #"dump-package gave no package description: {"products": []}"#)
        XCTAssertEqual(error { try Packages.manifest(json: "error: manifest parse error") },
                       "dump-package gave no package description: error: manifest parse error")
    }

    func testRemoteDependenciesBuildOnlyFromTheResolvedFile() throws {
        XCTAssertEqual(try UITestEngine.remoteDependencies(of: "/repo/Packages/Other", manifest: manifests), [])
        // Through the package Core uses by path.
        XCTAssertEqual(try UITestEngine.remoteDependencies(of: "/repo/Packages/Core", manifest: manifests), ["swift-algorithms"])
        XCTAssertEqual(try Packages.resolutionArguments(dir: "/repo/Packages/Other", remote: [], hasResolvedFile: false), [])
        XCTAssertEqual(try Packages.resolutionArguments(dir: "/repo/Packages/Core", remote: ["swift-algorithms"], hasResolvedFile: true),
                       ["--only-use-versions-from-resolved-file"])
        XCTAssertEqual(error { try Packages.resolutionArguments(dir: "/repo/Packages/Core", remote: ["swift-algorithms"], hasResolvedFile: false) },
                       "the package in /repo/Packages/Core uses remote packages (swift-algorithms) and has no Package.resolved, so simless can't build it "
                       + "without choosing their versions; resolve them (`swift package resolve` in /repo/Packages/Core) and run again")
    }

    func testTheManifestCacheKeysOnEveryManifestsContent() throws {
        let dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "// swift-tools-version: 6.0\n".write(toFile: "\(dir)/Package.swift", atomically: true, encoding: .utf8)
        let first = Packages.manifestDigest(dir)
        try "// swift-tools-version: 6.1\n".write(toFile: "\(dir)/Package.swift", atomically: true, encoding: .utf8)
        let edited = Packages.manifestDigest(dir)
        XCTAssertNotEqual(first, edited)
        try "// swift-tools-version: 5.9\n".write(toFile: "\(dir)/Package@swift-5.9.swift", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(edited, Packages.manifestDigest(dir))
        try "other".write(toFile: "\(dir)/Other.swift", atomically: true, encoding: .utf8)
        let withOther = Packages.manifestDigest(dir)
        try FileManager.default.removeItem(atPath: "\(dir)/Other.swift")
        XCTAssertEqual(withOther, Packages.manifestDigest(dir))
    }

    func testTheBundleTargetsTheNewestMacOSOfItsPackages() {
        XCTAssertEqual(UITestEngine.macOSVersion(packages: []), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: [nil, "13.0"]), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["15.0", nil]), "15.0")
        // Compared by number, not by text.
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["10.15", "9.0"]), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["15.4", "15.10"]), "15.10")
    }

    func testOnlyTheModuleMapsOfCTargetsAreGiven() {
        XCTAssertEqual(Packages.cModuleMaps(["Base-Swift.h", "Base.modulemap", "CLib.modulemap", "Support.modulemap"], in: "/m",
                                            swiftModules: ["Base.swiftmodule", "Support.swiftmodule", "libSupport.a", "CLib.o"]),
                       ["/m/CLib.modulemap"])
    }

    func testTheBundleGetsEachPackagesModulesModuleMapsAndArchives() {
        XCTAssertEqual(UITestEngine.packageArguments([]), [])
        XCTAssertEqual(UITestEngine.packageArguments([MacProducts(bin: "/b/core", products: ["TestSupport", "Ledger"], moduleMaps: ["/m/CLib.modulemap"]),
                                                      MacProducts(bin: "/b/other", products: ["Charts"], moduleMaps: [])]), [
            "-I", "/b/core", "-Xcc", "-fmodule-map-file=/m/CLib.modulemap", "/b/core/libTestSupport.a", "/b/core/libLedger.a",
            "-I", "/b/other", "/b/other/libCharts.a",
        ])
    }

    func testTheBundleCommandHasThePackagesAndTheirMacOS() {
        let core = MacProducts(bin: "/b/core", products: ["TestSupport"], moduleMaps: [])
        let command = UITestEngine.bundleCommand(module: "AppUITests", macOS: "15.0", sdk: "/sdk", swiftVersion: "6", platform: "/p",
                                                 output: "/out/AppUITests", packages: [core], sources: ["/src/A.swift"])
        XCTAssertEqual(command.firstIndex(of: "-target").map { command[$0 + 1] }, "arm64-apple-macos15.0")
        XCTAssertEqual(Array(command.suffix(4)), ["-I", "/b/core", "/b/core/libTestSupport.a", "/src/A.swift"])
        XCTAssertFalse(UITestEngine.bundleCommand(module: "AppUITests", macOS: "14.0", sdk: "/sdk", swiftVersion: "6", platform: "/p",
                                                  output: "/out/AppUITests", packages: [], sources: ["/src/A.swift"]).contains("/b/core"))
    }

    func testTheBundleIsBuiltAgainWhenAPackageOrItsMacOSChanges() {
        let digest = { (path: String) -> String? in path == "/src/A.swift" ? "a1" : "s1" }
        func key(_ newest: Double = 100, products: [String] = ["TestSupport"], macOS: String = "15.0",
                 digest: @escaping (String) -> String? = digest, simless: Double = 1) -> String {
            UITestEngine.bundleKey(files: ["/src/A.swift", "/shim/X.swift"], digest: digest, packages: [("/repo/Core", newest, products)],
                                   macOS: macOS, simless: simless)
        }
        let base = key()
        XCTAssertEqual(base, key())
        XCTAssertNotEqual(base, key(101))
        XCTAssertNotEqual(base, key(products: ["TestSupport", "Ledger"]))
        XCTAssertNotEqual(base, key(macOS: "14.0"))
        XCTAssertNotEqual(base, key(digest: { $0 == "/src/A.swift" ? "a2" : "s1" }))
        XCTAssertNotEqual(base, key(simless: 2))
        XCTAssertNotEqual(base, UITestEngine.bundleKey(files: ["/src/A.swift", "/shim/X.swift"], digest: digest, packages: [],
                                                       macOS: "15.0", simless: 1))
    }

    /// Builds a package for the Mac whose two products both use a Swift target
    /// that imports a C target, and links both archives into one bundle that
    /// imports both products.
    func testBuildsProductsThatShareTargetsForTheMacAndLinksThemIntoABundle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMLESS_SLOW_TESTS"] == "1", "set SIMLESS_SLOW_TESTS=1 to build a package with swift build")
        let dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let package = "\(dir)/Core"
        func write(_ text: String, _ path: String) throws {
            try FileManager.default.createDirectory(atPath: ("\(package)/\(path)" as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: "\(package)/\(path)", atomically: true, encoding: .utf8)
        }
        try write("""
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Core",
                platforms: [.macOS(.v15)],
                products: [.library(name: "Support", targets: ["Support"]), .library(name: "Extra", targets: ["Extra"])],
                targets: [.target(name: "CLib"), .target(name: "Base", dependencies: ["CLib"]),
                          .target(name: "Support", dependencies: ["Base"]), .target(name: "Extra", dependencies: ["Base"])]
            )
            """, "Package.swift")
        try write("int clib_value(void);\n", "Sources/CLib/include/clib.h")
        try write("#include \"clib.h\"\nint clib_value(void) { return 7; }\n", "Sources/CLib/clib.c")
        try write("import CLib\npublic enum Base { public static func value() -> Int { Int(clib_value()) } }\n", "Sources/Base/Base.swift")
        try write("import Base\npublic enum Support { public static func value() -> Int { Base.value() } }\n", "Sources/Support/Support.swift")
        try write("import Base\npublic enum Extra { public static func value() -> Int { Base.value() + 1 } }\n", "Sources/Extra/Extra.swift")

        let manifest = try Packages.manifest(json: Packages.dumpPackage(package))
        XCTAssertEqual(manifest, Self.manifest("Core", ["Support", "Extra"], macOS: "15.0"))
        let built = try Packages.buildForMac(dir: package, products: ["Support", "Extra"], remote: [], scratch: "\(dir)/scratch", logs: dir)
        XCTAssertEqual(built.moduleMaps.map { ($0 as NSString).lastPathComponent }, ["CLib.modulemap"])
        // The build wrote nothing into the package.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package).sorted(), ["Package.swift", "Sources"])

        let user = "\(dir)/User.swift"
        try "import Support\nimport Extra\npublic func userValue() -> Int { Support.value() + Extra.value() }\n"
            .write(toFile: user, atomically: true, encoding: .utf8)
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = "\(dir)/User.bundle"
        let target = "arm64-apple-macos\(UITestEngine.macOSVersion(packages: [manifest.macOS]))"
        let r = try Shell.run(["xcrun", "swiftc", "-emit-library", "-Xlinker", "-bundle", "-target", target, "-sdk", sdk, "-o", out]
                              + UITestEngine.packageArguments([built]) + [user])
        XCTAssertEqual(r.code, 0, r.out)
        // The code of every target is in the bundle: each archive carries the targets its product uses.
        let symbols = try Shell.check(["nm", out])
        for name in ["_clib_value", "4Base", "7Support", "5Extra"] { XCTAssertTrue(symbols.contains(name), name) }
    }
}
