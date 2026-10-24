// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Which package products a UI test target links, where each comes from, and
/// what the bundle build gets for them.
final class UITestPackageProductsTests: XCTestCase {
    /// A project with a UI test target that links `products` (id, product name,
    /// package id or nil), a local package `Core` and a remote package.
    private func pbx(_ products: [(String, String, String?)]) -> String {
        let deps = products.map { "\t\t\t\t\($0.0) /* \($0.1) */," }.joined(separator: "\n")
        let objects = products.map { id, name, package in
            "\t\t\(id) /* \(name) */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
                + (package.map { "\t\t\tpackage = \($0) /* package */;\n" } ?? "")
                + "\t\t\tproductName = \(name);\n\t\t};"
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

    private let core = PackageManifest(name: "Core", products: ["TestSupport", "Ledger"], macOS: "15.0")
    private let other = PackageManifest(name: "Other", products: ["Charts"], macOS: nil)

    private func manifests(_ dir: String) throws -> PackageManifest {
        switch dir {
        case "/repo/Packages/Core": return core
        case "/repo/Packages/Other": return other
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
                           ("BBBBBBBBBBBBBBBBBBBBBBB4", "Gone", "CCCCCCCCCCCCCCCCCCCCCCC9")])
        XCTAssertEqual(PBX.packageProducts(target: "AppUITests", pbx: project), [
            PBX.PackageProduct(name: "TestSupport", package: .unnamed),
            PBX.PackageProduct(name: "Ledger", package: .local("Packages/Core")),
            PBX.PackageProduct(name: "SnapshotTesting", package: .remote("https://github.com/pointfreeco/swift-snapshot-testing")),
            PBX.PackageProduct(name: "Gone", package: .unknown("CCCCCCCCCCCCCCCCCCCCCCC9")),
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

    func testAProductOfARemotePackageStopsTheBuild() {
        let message = error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB3", "SnapshotTesting", "AAAAAAAAAAAAAAAAAAAAAAA3")])) }
        XCTAssertEqual(message, "AppUITests links the package product SnapshotTesting from the remote package "
                       + "https://github.com/pointfreeco/swift-snapshot-testing; simless builds a UI test bundle only with products of local packages")
    }

    func testAProductThatNoPackageDeclaresStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Missing", nil)])) },
                       "AppUITests links the package product Missing, which no local package declares "
                       + "(looked in /repo/Packages/Core, /repo/Packages/Other)")
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "TestSupport", nil)]), local: []) },
                       "AppUITests links the package product TestSupport, which no local package declares (the project has no local package)")
        // The named package doesn't declare it.
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Charts", "AAAAAAAAAAAAAAAAAAAAAAA2")])) },
                       "AppUITests links the package product Charts, which no local package declares (looked in /repo/Packages/Core)")
    }

    func testAPackageReferenceSimlessCantReadStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB4", "Gone", "CCCCCCCCCCCCCCCCCCCCCCC9")])) },
                       "AppUITests links the package product Gone from a package reference that simless can't read (CCCCCCCCCCCCCCCCCCCCCCC9)")
    }

    func testAManifestThatCantBeReadStopsTheBuild() {
        XCTAssertEqual(error { try linked(pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "TestSupport", nil)]), local: ["/repo/Broken"]) },
                       "AppUITests links the package product TestSupport, and simless can't read the package in /repo/Broken: no manifest at /repo/Broken")
    }

    func testAProductThatTwoPackagesDeclareStopsTheBuild() {
        let twice = { (dir: String) throws -> PackageManifest in PackageManifest(name: dir, products: ["Charts"], macOS: nil) }
        XCTAssertEqual(error {
            try UITestEngine.linkedProducts(target: "AppUITests", pbx: self.pbx([("BBBBBBBBBBBBBBBBBBBBBBB1", "Charts", nil)]), projectDir: "/repo",
                                            localPackages: ["/repo/A", "/repo/B"], manifest: twice)
        }, "AppUITests links the package product Charts, which more than one local package declares (/repo/A, /repo/B)")
    }

    func testATargetWithNoPackageProductsLinksNothing() throws {
        XCTAssertEqual(try linked(pbx([])), [])
    }

    func testReadsProductsAndMacOSFromDumpPackage() throws {
        let json = #"""
            {"name": "LoadbudgetCore",
             "platforms": [{"options": [], "platformName": "ios", "version": "18.0"},
                           {"options": [], "platformName": "macos", "version": "15.0"}],
             "products": [{"name": "LoadbudgetLedger", "targets": ["LoadbudgetLedger"], "type": {"library": ["automatic"]}},
                          {"name": "LoadbudgetTestSupport", "targets": ["LoadbudgetTestSupport"], "type": {"library": ["automatic"]}}],
             "dependencies": []}
            """#
        XCTAssertEqual(try Packages.manifest(json: json),
                       PackageManifest(name: "LoadbudgetCore", products: ["LoadbudgetLedger", "LoadbudgetTestSupport"], macOS: "15.0"))
        XCTAssertEqual(try Packages.manifest(json: #"{"name": "Bare", "platforms": [], "products": []}"#),
                       PackageManifest(name: "Bare", products: [], macOS: nil))
        XCTAssertThrowsError(try Packages.manifest(json: #"{"products": []}"#))
    }

    func testTheBundleTargetsTheNewestMacOSOfItsPackages() {
        XCTAssertEqual(UITestEngine.macOSVersion(packages: []), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: [nil, "13.0"]), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["15.0", nil]), "15.0")
        // Compared by number, not by text.
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["10.15", "9.0"]), "14.0")
        XCTAssertEqual(UITestEngine.macOSVersion(packages: ["15.4", "15.10"]), "15.10")
    }

    func testTheBundleGetsEachPackagesModulesAndArchives() {
        XCTAssertEqual(UITestEngine.packageArguments([]), [])
        XCTAssertEqual(UITestEngine.packageArguments([("/b/core", ["TestSupport", "Ledger"]), ("/b/other", ["Charts"])]), [
            "-I", "/b/core", "/b/core/libTestSupport.a", "/b/core/libLedger.a",
            "-I", "/b/other", "/b/other/libCharts.a",
        ])
    }

    /// Builds a package with a product whose target depends on another target,
    /// for the Mac, and links its archive into a bundle that imports it.
    func testBuildsAProductForTheMacAndLinksItIntoABundle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMLESS_SLOW_TESTS"] == "1", "set SIMLESS_SLOW_TESTS=1 to build a package with swift build")
        let dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let package = "\(dir)/Core"
        try FileManager.default.createDirectory(atPath: "\(package)/Sources/Base", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(package)/Sources/Support", withIntermediateDirectories: true)
        try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Core",
                platforms: [.macOS(.v15)],
                products: [.library(name: "Support", targets: ["Support"])],
                targets: [.target(name: "Base"), .target(name: "Support", dependencies: ["Base"])]
            )
            """.write(toFile: "\(package)/Package.swift", atomically: true, encoding: .utf8)
        try "public enum Base { public static let word = \"base\" }\n"
            .write(toFile: "\(package)/Sources/Base/Base.swift", atomically: true, encoding: .utf8)
        try "import Base\npublic enum Support { public static func word() -> String { Base.word + \"-support\" } }\n"
            .write(toFile: "\(package)/Sources/Support/Support.swift", atomically: true, encoding: .utf8)

        let manifest = try Packages.manifest(json: Packages.dumpPackage(package))
        XCTAssertEqual(manifest, PackageManifest(name: "Core", products: ["Support"], macOS: "15.0"))
        let bin = try Packages.buildForMac(dir: package, products: ["Support"], scratch: "\(dir)/scratch", logs: dir)

        let user = "\(dir)/User.swift"
        try "import Support\npublic func userWord() -> String { Support.word() }\n".write(toFile: user, atomically: true, encoding: .utf8)
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = "\(dir)/User.bundle"
        let target = "arm64-apple-macos\(UITestEngine.macOSVersion(packages: [manifest.macOS]))"
        let r = try Shell.run(["xcrun", "swiftc", "-emit-library", "-Xlinker", "-bundle", "-target", target, "-sdk", sdk, "-o", out]
                              + UITestEngine.packageArguments([(bin, ["Support"])]) + [user])
        XCTAssertEqual(r.code, 0, r.out)
        // Both targets' code is in the bundle: the archive carries the target the product depends on.
        let symbols = try Shell.check(["nm", out])
        XCTAssertTrue(symbols.contains("4Base"), symbols)
        XCTAssertTrue(symbols.contains("7Support"), symbols)
    }
}
