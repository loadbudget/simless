// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// UI tests without a simulator.
///
/// The UI test target's sources are compiled unchanged for macOS together with
/// simless's XCUITest API (Templates/XCUI), whose XCUIApplication, XCUIElement
/// and queries shadow XCTest's. The tests run in `xctest` on the Mac and drive
/// headless hosts of the app through SimlessRuntime: queries read the app's
/// accessibility tree, taps and gestures are real touches in its process.
/// Several hosts run side by side (UI slots "ui1"...), each its own installed
/// copy of the app, so test classes run in parallel without simulator clones.
enum UITestEngine {
    struct UITarget {
        let name: String
        let sources: [String]
        /// In the scheme's build. A UI test target that isn't (a watch app's,
        /// say) can't run here, but its tests are still listed.
        var built = true
    }

    struct TestID: Hashable {
        let target: String, cls: String, method: String
        var user: String { "\(target)/\(cls)/\(method)" }
        var xctest: String { "\(TestEngine.moduleName(target)).\(cls)/\(method)" }
    }

    // MARK: - Targets

    /// UI test targets in the build (the .xctestrun's UI test bundles), with
    /// their sources: the target's synchronized folders, the files of its
    /// Sources build phase, and the folder tests.uiSources names; failing all
    /// three, a folder named like the target.
    static func targets(_ ws: Workspace, includingUnbuilt: Bool = false) -> [UITarget] {
        let names = builtTargetNames(ws)
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        let unbuilt = includingUnbuilt ? uiTestTargets(pbx: pbx).subtracting(names) : []
        return (names.union(unbuilt)).sorted().compactMap { name in
            let sources = sourceFiles(target: name, pbx: pbx, projectDir: ws.projectDir, root: ws.root,
                                      uiSources: ws.config.tests?.uiSources?[name])
            return sources.isEmpty ? nil : UITarget(name: name, sources: sources, built: !unbuilt.contains(name))
        }
    }

    /// The Swift files of one UI test target, as absolute, standardized paths.
    /// The folder named like the target counts only when the target has no
    /// synchronized folder, lists no Swift file and has no tests.uiSources.
    static func sourceFiles(target: String, pbx: String, projectDir: String, root: String, uiSources: String?) -> [String] {
        let dirs = PBX.synchronizedFolders(target: target, pbx: pbx).map { absolute($0, in: projectDir) } + (uiSources.map { [absolute($0, in: root)] } ?? [])
        let listed = PBX.sourceFiles(target: target, pbx: pbx).filter { $0.hasSuffix(".swift") }.map { absolute($0, in: projectDir) }
        let folders = dirs.isEmpty && listed.isEmpty ? ["\(projectDir)/\(target)"].filter { exists($0) } : dirs
        let found = folders.flatMap { dir -> [String] in
            guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
            return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "\(dir)/\($0)" }
        }
        return Set((found + listed).map(standardized)).sorted()
    }

    private static func absolute(_ path: String, in dir: String) -> String { path.hasPrefix("/") ? path : "\(dir)/\(path)" }
    private static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// The UI test sources that no other target compiles, by its Sources build
    /// phase or a synchronized folder. Only those can leave the record of the
    /// app's build: a file the app compiles too is an input of that build.
    static func uiOnlySources(_ ws: Workspace) -> Set<String> {
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        return uiOnly(targets(ws, includingUnbuilt: true).flatMap(\.sources), pbx: pbx, projectDir: ws.projectDir)
    }

    static func uiOnly(_ sources: [String], pbx: String, projectDir: String) -> Set<String> {
        let others = Set(PBX.targetNames(pbx: pbx)).subtracting(uiTestTargets(pbx: pbx))
        let files = Set(others.flatMap { PBX.sourceFiles(target: $0, pbx: pbx) }.map { standardized(absolute($0, in: projectDir)) })
        let folders = others.flatMap { PBX.synchronizedFolders(target: $0, pbx: pbx) }.map { standardized(absolute($0, in: projectDir)) + "/" }
        return Set(sources.map(standardized).filter { file in !files.contains(file) && !folders.contains { file.hasPrefix($0) } })
    }

    /// The UI test bundles in the scheme's .xctestrun.
    static func builtTargetNames(_ ws: Workspace) -> Set<String> {
        guard let file = ws.appXCTestRun,
              let data = FileManager.default.contents(atPath: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        let entries: [[String: Any]]
        if let configs = plist["TestConfigurations"] as? [[String: Any]] {
            entries = configs.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            entries = plist.filter { !$0.key.hasPrefix("__") }.compactMap { $0.value as? [String: Any] }
        }
        return Set(entries.filter { $0["IsUITestBundle"] as? Bool == true }.compactMap { $0["BlueprintName"] as? String })
    }

    /// Every UI test target in the project, built or not.
    static func uiTestTargets(pbx: String) -> Set<String> {
        var out = Set<String>()
        for block in pbx.components(separatedBy: "isa = PBXNativeTarget;").dropFirst() {
            let body = block.components(separatedBy: "\n\t\t};").first ?? ""
            guard body.contains("com.apple.product-type.bundle.ui-testing"),
                  let name = body.firstMatch(of: #/\n\t\t\tname = "?([^";]+)"?;/#) else { continue }
            out.insert(String(name.1))
        }
        return out
    }

    /// What the sources of a UI test target declare.
    struct Discovery {
        /// Test methods per class.
        var tests: [TestID] = []
        /// A class with tests in its chain whose superclass no file of the
        /// target declares (in a package, say), so its chain can't reach XCTestCase.
        var unknownSuperclasses: [(cls: String, superclass: String)] = []
    }

    static func tests(in target: UITarget) -> [TestID] { discover(target).tests }

    /// Test methods per class, from the sources. A class runs tests when its
    /// chain of superclasses, declared in any file of the target, reaches
    /// XCTestCase. Its tests are the `func test...()` methods with no result,
    /// at the top of its body or of an `extension <Class>` block in any file,
    /// and those of its superclasses, as XCTest runs inherited tests. A class
    /// with no such method yields none. Methods in a private extension, and
    /// private methods, don't run in XCTest and aren't listed.
    static func discover(_ target: UITarget) -> Discovery {
        let decl = #/^(?:@\w+(?:\([^)]*\))?\s+)*((?:(?:public|open|internal|private|fileprivate|final)\s+)*)/#
        let method = #/^\s+(?:(?:@\w+(?:\([^)]*\))?|public|open|internal|final|override|nonisolated|dynamic)\s+)*func\s+(test\w*)\s*\(\s*\)([^{]*)/#
        var superclass: [String: String] = [:]
        var declared: [String] = []                // classes, in source order
        var methods: [(type: String, name: String)] = []
        for file in target.sources {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            var type: String?
            var depth = 0
            var lexer = CodeLexer()
            // Only what an iPhone simulator run would compile (see PlatformConditions).
            for raw in PlatformConditions.activeLines(text) {
                let line = lexer.code(raw)
                let start = depth
                depth = max(0, depth + line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count)
                if start == 0 {
                    // A declaration at the top level, after its attributes and modifiers.
                    let trimmed = line.drop { $0 == " " || $0 == "\t" }
                    let m = trimmed.prefixMatch(of: decl)
                    let rest = m.map { trimmed[$0.range.upperBound...] } ?? trimmed
                    let isPrivate = m.map { $0.output.1.contains("private") } ?? false
                    if let c = rest.firstMatch(of: #/^class\s+(\w+)\s*(?:<[^>{]*>)?\s*(?::\s*(?:\w+\.)?(\w+))?/#) {
                        type = String(c.1)
                        declared.append(String(c.1))
                        if let s = c.2 { superclass[String(c.1)] = String(s) }
                    } else if let e = rest.firstMatch(of: #/^extension\s+(?:\w+\.)?(\w+)\b/#) {
                        type = isPrivate ? nil : String(e.1)
                    } else if rest.first.map({ $0.isLetter || $0 == "@" }) == true {
                        // Another declaration; a brace on its own line keeps the class.
                        type = nil
                    }
                    continue
                }
                if start == 1, let t = type, let m = line.prefixMatch(of: method), !m.output.2.contains("->") {
                    methods.append((t, String(m.1)))
                }
            }
        }
        let withTests = Set(methods.map(\.type))
        var out = Discovery()
        var seen = Set<TestID>()
        var reported = Set<String>()
        for c in declared {
            // c first, then its superclasses, while a file declares them.
            var chain = [c]
            var end: String?
            while chain.count < 64, let s = superclass[chain.last!] {
                if s == "XCTestCase" { end = s; break }
                if chain.contains(s) || !declared.contains(s) { break }
                chain.append(s)
            }
            if end == nil, let last = chain.last, let s = superclass[last], s != "XCTestCase", s != "NSObject", !declared.contains(s),
               !withTests.isDisjoint(with: chain), reported.insert(last).inserted {
                out.unknownSuperclasses.append((last, s))
            }
            guard end != nil else { continue }
            let members = Set(chain)
            for m in methods where members.contains(m.type) {
                let id = TestID(target: target.name, cls: c, method: m.name)
                if seen.insert(id).inserted { out.tests.append(id) }
            }
        }
        return out
    }

    /// The code of each line, without comments and the text of string
    /// literals, so braces and declarations in them don't count.
    struct CodeLexer {
        private var inComment = false
        private var inMultiline = false

        mutating func code(_ line: Substring) -> String {
            var out = ""
            var i = line.startIndex
            func at(_ s: String) -> Bool { line[i...].hasPrefix(s) }
            while i < line.endIndex {
                if inComment {
                    if at("*/") { inComment = false; i = line.index(i, offsetBy: 2) } else { i = line.index(after: i) }
                } else if inMultiline {
                    if at("\"\"\"") { inMultiline = false; out += "\"\""; i = line.index(i, offsetBy: 3) } else { i = line.index(after: i) }
                } else if at("//") {
                    break
                } else if at("/*") {
                    inComment = true; i = line.index(i, offsetBy: 2)
                } else if at("\"\"\"") {
                    inMultiline = true; i = line.index(i, offsetBy: 3)
                } else if line[i] == "\"" {
                    // A one-line literal: its text goes, up to the closing quote.
                    out += "\"\""
                    i = line.index(after: i)
                    while i < line.endIndex && line[i] != "\"" {
                        i = line.index(i, offsetBy: line[i] == "\\" && line.index(after: i) < line.endIndex ? 2 : 1)
                    }
                    if i < line.endIndex { i = line.index(after: i) }
                } else {
                    out.append(line[i]); i = line.index(after: i)
                }
            }
            return out
        }
    }

    // MARK: - Package products

    /// A package product that a UI test target links, and the local package that declares it.
    struct LinkedProduct: Equatable {
        let name: String
        let packageDir: String
        let manifest: PackageManifest
    }

    /// The products in `target`'s `packageProductDependencies`, each with the
    /// local package that declares it: the package the project file names, or
    /// when it names none, the one of `localPackages` (absolute directories)
    /// whose manifest declares the product. A product of a remote package, of a
    /// package reference simless can't read, or that no package or two
    /// packages declare, stops the build with an error that names it and the target.
    static func linkedProducts(target: String, pbx: String, projectDir: String, localPackages: [String],
                               manifest: (String) throws -> PackageManifest) throws -> [LinkedProduct] {
        try PBX.packageProducts(target: target, pbx: pbx).map { p in
            let candidates: [String]
            switch p.package {
            case .remote(let url):
                throw SimlessError("\(target) links the package product \(p.name) from the remote package \(url); "
                                   + "simless builds a UI test bundle only with products of local packages")
            case .unknown(let what):
                throw SimlessError("\(target) links the package product \(p.name) from a package reference that simless can't read (\(what))")
            case .local(let path):
                candidates = [standardized(absolute(path, in: projectDir))]
            case .unnamed:
                candidates = localPackages.map(standardized)
            }
            let declaring = try candidates.compactMap { dir -> (String, PackageManifest)? in
                let m: PackageManifest
                do { m = try manifest(dir) } catch {
                    throw SimlessError("\(target) links the package product \(p.name), and simless can't read the package in \(dir): \(error)")
                }
                return m.products.contains(p.name) ? (dir, m) : nil
            }
            guard declaring.count == 1, let (dir, m) = declaring.first else {
                let looked = candidates.isEmpty ? "the project has no local package" : "looked in \(candidates.joined(separator: ", "))"
                throw SimlessError(declaring.isEmpty
                    ? "\(target) links the package product \(p.name), which no local package declares (\(looked))"
                    : "\(target) links the package product \(p.name), which more than one local package declares (\(declaring.map(\.0).joined(separator: ", ")))")
            }
            return LinkedProduct(name: p.name, packageDir: dir, manifest: m)
        }
    }

    /// The macOS a UI test bundle is built for: 14.0, or the newest macOS
    /// that a package it links builds for, since a module can't be imported
    /// by code built for an older macOS than its own.
    static func macOSVersion(packages: [String?]) -> String {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        return (["14.0"] + packages.compactMap { $0 }).max { parts($0).lexicographicallyPrecedes(parts($1)) }!
    }

    /// The products of each package, packages in path order and products in the project file's order.
    static func productsByPackage(_ linked: [LinkedProduct]) -> [(dir: String, products: [String])] {
        Dictionary(grouping: linked, by: \.packageDir).sorted { $0.key < $1.key }.map { ($0.key, $0.value.map(\.name)) }
    }

    /// The compiler arguments that give the bundle the modules and archives
    /// of the products, from the folder each package was built into.
    static func packageArguments(_ built: [(bin: String, products: [String])]) -> [String] {
        built.flatMap { b in ["-I", b.bin] + b.products.map { "\(b.bin)/lib\($0).a" } }
    }

    // MARK: - Build

    /// The UI test target compiled for macOS with simless's XCUITest API, and
    /// linked with the local package products the target links.
    static func build(_ target: UITarget, ws: Workspace) throws -> String {
        let dir = "\(ws.work)/UITests"
        let bundle = "\(dir)/\(target.name).xctest"
        let exe = "\(bundle)/Contents/MacOS/\(target.name)"
        let shim = ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.toolRoot)/Templates/XCUI")) ?? [])
            .filter { $0.hasSuffix(".swift") }.map { "\(Paths.toolRoot)/Templates/XCUI/\($0)" }
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        let linked = try linkedProducts(target: target.name, pbx: pbx, projectDir: ws.projectDir,
                                        localPackages: Workspace.localPackages(root: ws.root, project: ws.config.project).map { "\(ws.root)/\($0)" },
                                        manifest: { try Packages.manifest(dir: $0, ws: ws) })
        let packages = productsByPackage(linked)
        let macOS = macOSVersion(packages: linked.map(\.manifest.macOS))
        // Built from exactly these files with exactly this content (a deleted
        // file or one put back to an older version counts too), by this simless,
        // and from the linked packages as of their newest file.
        let key = shortHash(((target.sources + shim).sorted().map { "\($0) \(Workspace.digest($0) ?? "")" }
                             + packages.map { "\($0.dir) \(Packages.newestSource($0.dir)) \($0.products.joined(separator: ","))" }
                             + ["macOS \(macOS)", "\(mtime(Bundle.main.executablePath ?? ""))"]).joined(separator: "\n"))
        let keyFile = "\(bundle)/Contents/simless-sources"
        if exists(exe), (try? String(contentsOfFile: keyFile, encoding: .utf8)) == key { return bundle }
        try? FileManager.default.removeItem(atPath: keyFile)
        let t = now()
        let p = "\(RuntimeBuild.developerDir)/Platforms/MacOSX.platform/Developer"
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try mkdirp("\(bundle)/Contents/MacOS")
        let settings = try ws.settings()
        let log = "\(dir)/build-\(target.name).log"
        // Sources with platform conditions are compiled from a rewritten copy that
        // keeps the original's file name and line numbers.
        let rewritten = "\(dir)/sources-\(target.name)"
        try? FileManager.default.removeItem(atPath: rewritten)
        try mkdirp(rewritten)
        var sources: [String] = []
        for (i, file) in target.sources.enumerated() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8), PlatformConditions.needsRewrite(text) else {
                sources.append(file); continue
            }
            let copy = "\(rewritten)/\(i)-\((file as NSString).lastPathComponent)"
            try ("#sourceLocation(file: \"\(file)\", line: 1)\n" + PlatformConditions.rewrite(text))
                .write(toFile: copy, atomically: true, encoding: .utf8)
            sources.append(copy)
        }
        var built: [(bin: String, products: [String])] = []
        for p in packages {
            Log.step("building \(p.products.joined(separator: ", ")) for the Mac, which \(target.name) links")
            do {
                built.append((try Packages.buildForMac(dir: p.dir, products: p.products, scratch: "\(dir)/packages/\(shortHash(p.dir))", logs: dir),
                              p.products))
            } catch {
                throw SimlessError("\(target.name): \(error)")
            }
        }
        let r = try Shell.run(["xcrun", "swiftc", "-D", PlatformConditions.trueFlag, "-emit-library", "-Onone", "-g", "-module-name", TestEngine.moduleName(target.name),
                               "-target", "arm64-apple-macos\(macOS)", "-sdk", sdk, "-swift-version", settings.swiftVersion,
                               "-F", "\(p)/Library/Frameworks", "-I", "\(p)/usr/lib", "-L", "\(p)/usr/lib",
                               "-framework", "XCTest", "-Xlinker", "-bundle",
                               "-Xlinker", "-rpath", "-Xlinker", "\(p)/Library/Frameworks",
                               "-Xlinker", "-rpath", "-Xlinker", "\(p)/usr/lib",
                               "-o", exe] + packageArguments(built) + sources + shim, cwd: ws.root, logPath: log)
        guard r.code == 0 else {
            throw SimlessError("building \(target.name) for simless failed (log: \(log)):\n" + Patch.compilerErrors(r.out))
        }
        let info: [String: Any] = ["CFBundleExecutable": target.name, "CFBundleIdentifier": "simless.uitests.\(target.name)",
                                   "CFBundlePackageType": "BNDL", "CFBundleName": target.name,
                                   "NSPrincipalClass": "SimlessXCUIObserver"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: "\(bundle)/Contents/Info.plist"))
        try key.write(toFile: keyFile, atomically: true, encoding: .utf8)
        Log.step("built \(target.name) for the Mac in \(secs(t))")
        return bundle
    }

    // MARK: - Run

    /// UI tests on every device asked for, one after another, with one
    /// results file for all. `--device iphone,ipad` runs everything on each;
    /// tests.uiDevices adds devices that run only the tests listed for them.
    static func runDevices(_ args: Args, ws: Workspace, filters: [String]) throws -> Bool {
        var plan: [(device: String, filters: [String])] = []
        if let asked = args.values["--device"] {
            plan = asked.split(separator: ",").map { (String($0), filters) }
        } else {
            plan = [(ws.config.device, filters)]
            for (device, ids) in (ws.config.tests?.uiDevices ?? [:]).sorted(by: { $0.key < $1.key }) where device != ws.config.device {
                // The device's own tests, narrowed to what this run selected.
                let wanted = ids.isEmpty ? filters : filters.isEmpty ? ids
                    : ids.filter { id in filters.contains { f in TestEngine.matches(id, f) || TestEngine.matches(f, id) } }
                        + filters.filter { f in ids.contains { TestEngine.matches(f, $0) } }
                if ids.isEmpty || !wanted.isEmpty { plan.append((device, Array(Set(wanted)).sorted())) }
            }
        }
        guard plan.count > 1 else { return try run(args, ws: ws, filters: plan.first?.filters ?? filters) }
        let path = "\(ws.work)/ui-test-results.json"
        var ok = true
        var perDevice: [String: [String: Any]] = [:]
        for (device, selection) in plan {
            var one = args
            one.values["--device"] = device
            print("\n== UI tests on \(device)\(selection.isEmpty ? "" : ": \(selection.count) selection(s)") ==")
            ok = try run(one, ws: ws, filters: selection) && ok
            if let d = FileManager.default.contents(atPath: path), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                perDevice[device] = r
                try? d.write(to: URL(fileURLWithPath: "\(ws.work)/ui-test-results-\(device).json"))
            }
        }
        try saveMatrix(perDevice, to: path)
        print("\(ok ? "PASSED" : "FAILED") on \(plan.map(\.device).joined(separator: " and ")) (results: \(path))")
        return ok
    }

    /// One status per test across devices: a failure anywhere fails it, else
    /// a pass anywhere passes it (a test can skip itself on a phone and run on an iPad).
    static func saveMatrix(_ perDevice: [String: [String: Any]], to path: String) throws {
        let rank = ["failed": 6, "crashed": 6, "not-run": 5, "flaky": 4, "passed": 3, "simulator-only": 2, "not-built": 1, "excluded": 1, "skipped": 0]
        var tests: [String: [String: Any]] = [:]
        for (device, r) in perDevice {
            for (id, entry) in (r["tests"] as? [String: [String: Any]]) ?? [:] {
                var merged = tests[id] ?? ["devices": [String: Any]()]
                var devices = merged["devices"] as? [String: Any] ?? [:]
                devices[device] = entry
                merged["devices"] = devices
                let status = entry["status"] as? String ?? "skipped"
                let current = merged["status"] as? String
                // Failures win, then a pass over a skip.
                if (rank[status] ?? 0) >= (current.flatMap { rank[$0] } ?? -1) { merged["status"] = status }
                tests[id] = merged
            }
        }
        func with(_ statuses: Set<String>) -> [String] { tests.filter { statuses.contains($0.value["status"] as? String ?? "") }.keys.sorted() }
        // The same fields as one device's file, so a merge script reads both the same way.
        let notRun = Set(perDevice.values.flatMap { $0["notRun"] as? [String] ?? [] }).union(with(["not-run"])).sorted()
        let bad = with(["failed", "crashed"])
        let out: [String: Any] = ["ok": bad.isEmpty && notRun.isEmpty && perDevice.values.allSatisfy { $0["ok"] as? Bool ?? false },
                                  "selected": with(["passed", "failed", "crashed", "skipped", "flaky", "not-run"]).count,
                                  "notRun": notRun, "flaky": with(["flaky"]), "failing": bad,
                                  "devices": perDevice.keys.sorted(), "tests": tests]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    static func run(_ args: Args, ws: Workspace, filters: [String]) throws -> Bool {
        let t = now()
        let every = targets(ws, includingUnbuilt: true)
        let all = every.filter(\.built)
        guard !all.isEmpty else { throw noTargetsError(ws) }
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        for target in all {
            for f in PBX.unresolvedSwiftFiles(target: target.name, pbx: pbx) {
                Log.info("note: \(target.name) compiles \(f.name) from \(f.sourceTree), which simless doesn't read; it's left out")
            }
            for u in discover(target).unknownSuperclasses {
                Log.info("note: \(target.name): \(u.cls) inherits from \(u.superclass), which no file of the target declares, so its tests aren't found")
            }
        }
        let config = ws.config.tests
        let simulatorOnly = config?.simulatorOnly ?? [:]
        let skips = (config?.skip ?? []) + (args.repeated["--skip"] ?? []) + simulatorOnly.keys.sorted()
        let timeout = args.values["--timeout"].flatMap(Double.init) ?? config?.uiTimeout ?? TestEngine.defaultTimeout(args)

        // Selection.
        var selected: [TestID] = []
        var bundles: [String: String] = [:]
        var markedTests: [String: String] = [:]     // simulator-only tests this run would have run
        var excluded: [String] = []                 // --skip and tests.skip
        var unbuiltTests: [String] = []             // in a UI test target the scheme doesn't build
        var named: [String] = []                    // ...and asked for by name
        var missing: [String] = []                  // in the scheme, yet not in the build: never fine
        let inScheme = Set(SimulatorLane.schemes(ws).filter { $0.value == ws.config.scheme }.keys)
        for target in every where !target.built {
            let wanted = filters.isEmpty || filters.contains { $0 == target.name || $0.hasPrefix(target.name + "/") }
            if !wanted { continue }
            for id in tests(in: target) {
                if let mark = simulatorOnly.first(where: { TestEngine.matches(id.user, $0.key) }) { markedTests[id.user] = mark.value }
                else if inScheme.contains(target.name) && SimulatorLane.platform(target.name, ws: ws) == "iOS" { missing.append(id.user) }
                else {
                    unbuiltTests.append(id.user)
                    if !filters.isEmpty { named.append(id.user) }
                }
            }
        }
        // An id asked for that matches no UI test (renamed, deleted, mistyped)
        // counts as not run, unless --allow-missing.
        var unmatched: [String] = []
        if !args.flags.contains("--allow-missing") {
            let everyID = every.flatMap { tests(in: $0) }.map(\.user)
            for f in filters where !everyID.contains(where: { id in id == f || id.hasPrefix(f + "/") || f == String(id.split(separator: "/")[0])
                || id == f.replacingOccurrences(of: "()", with: "") }) {
                unmatched.append(f)
            }
        }
        if !missing.isEmpty {
            let targets = Set(missing.map { String($0.split(separator: "/")[0]) }).sorted()
            Log.info("note: \(targets.joined(separator: ", ")) is in the \(ws.config.scheme) scheme but not in the build; its \(missing.count) test(s) count as not run")
        }
        for target in all {
            let wanted = filters.isEmpty || filters.contains { $0 == target.name || $0.hasPrefix(target.name + "/") }
            if !wanted { continue }
            let asked = tests(in: target).filter { id in
                filters.isEmpty || filters.contains { f in id.user == f || id.user.hasPrefix(f + "/") || f == target.name
                    || id.user == f.replacingOccurrences(of: "()", with: "") }
            }
            for id in asked {
                if let mark = simulatorOnly.first(where: { TestEngine.matches(id.user, $0.key) }) { markedTests[id.user] = mark.value }
            }
            let skipped = { (id: TestID) in
                skips.contains { s in id.user == s.replacingOccurrences(of: "()", with: "") || id.user.hasPrefix(s + "/") || "\(target.name)/\(id.cls)" == s }
            }
            let ids = asked.filter { !skipped($0) }
            excluded += asked.filter { skipped($0) && markedTests[$0.user] == nil }.map(\.user)
            if ids.isEmpty { continue }
            Log.step("\(target.name): \(ids.count) UI test(s) selected from \(target.sources.count) source file(s)")
            bundles[target.name] = try build(target, ws: ws)
            selected += ids
        }
        if selected.isEmpty {
            // Nothing to run here is only fine when everything asked for is simulator-only.
            if !missing.isEmpty { throw SimlessError("no UI test ran: \(missing.count) test(s) in the \(ws.config.scheme) scheme aren't in the build (run `simless up`)") }
            if !unmatched.isEmpty { throw SimlessError("no UI test matches \(unmatched.joined(separator: " "))") }
            if !markedTests.isEmpty && named.isEmpty {
                try saveResults(ws: ws, results: Results(), selected: [], marked: markedTests, load: [], excluded: excluded, unbuilt: unbuiltTests)
                print("0 run here, \(markedTests.count) simulator-only (`simless test --simulator-only` lists them)")
                print("PASSED in \(secs(t))")
                return true
            }
            if !named.isEmpty { throw SimlessError("\(named[0]) is in a UI test target the scheme doesn't build, so it can't run here") }
            if filters.isEmpty && !excluded.isEmpty {
                throw SimlessError("every UI test is skipped: \(excluded.count) by --skip or tests.skip")
            }
            if filters.isEmpty { throw SimlessError(noTestsMessage(all)) }
            throw SimlessError("no UI tests match \(filters.joined(separator: " "))")
        }

        // Workers: one host each, tests spread by their last durations (longest
        // first onto the least busy host), each host keeping the source order.
        let durations = loadDurations(ws)
        let share = Budget.share(ws)
        let jobs = min(selected.count, args.values["--jobs"].flatMap(Int.init) ?? config?.uiJobs ?? max(1, Int(Double(defaultJobs) * share)))
        if share < 1 { Log.step("sharing the Mac with \(Int((1 / share).rounded()) - 1) other test run(s): \(jobs) UI host(s) instead of \(defaultJobs)") }
        Budget.start(ws, kind: "ui", hosts: jobs)
        defer { Budget.finish(ws) }
        var assigned = Array(repeating: [Int](), count: jobs)
        var load = Array(repeating: 0.0, count: jobs)
        for i in selected.indices.sorted(by: { (durations[selected[$0].user] ?? 10) > (durations[selected[$1].user] ?? 10) }) {
            let h = load.indices.min { load[$0] < load[$1] }!
            assigned[h].append(i)
            load[h] += durations[selected[i].user] ?? 10
        }
        let shards = assigned.map { $0.sorted().map { selected[$0] } }
        // The device the app runs as: an iPhone unless --device or .simless.json says otherwise.
        let device = args.values["--device"] ?? ws.config.device
        _ = try Render.canvas(device)
        Log.step("running \(selected.count) UI test(s) on \(jobs) host(s)\(device == "iphone" ? "" : " as \(device)")")
        var slots: [SlotRecord] = []
        for i in 1...jobs { slots.append(try RuntimeHost.slot(kind: "ui\(i)", ws: ws)) }
        // Every run starts from a fresh install's data, like a simulator's
        // clones: what earlier runs saved (counters, history, settings) would
        // make results depend on how often the suite ran before.
        // That launch also checks the slot: an install macOS won't open anymore
        // is installed again, rather than failing every test it gets.
        let settings = try ws.settings()
        DispatchQueue.concurrentPerform(iterations: slots.count) { i in
            let slot = slots[i]
            Slots.terminateAll(slot)
            if Native.isNative(slot) { return Native.wipe(slot) }
            let runtime = "\(slot.dir)/SimlessRuntime.dylib"
            guard let app = try? RuntimeHost.installedApp(slot), !Cleanup.wipeContainer(app: app, runtime: runtime) else { return }
            Log.step("\(slot.slotID)'s app wouldn't launch, installing it again")
            do {
                try Slots.prepare(slot, ws: ws, settings: settings, embedded: ws.config.embeddedBundles ?? true)
                try Slots.install(slot, ws: ws)
                if let app = try? RuntimeHost.installedApp(slot) { Cleanup.wipeContainer(app: app, runtime: runtime) }
            } catch {
                Log.info("note: installing \(slot.slotID) again failed (\(error))")
            }
        }

        // One folder per device, so a second device's run keeps the first one's screenshots.
        let artifacts = "\(ws.work)/ui-artifacts" + (args.values["--device"].map { $0 == ws.config.device ? "" : "-\($0)" } ?? "")
        try? FileManager.default.removeItem(atPath: artifacts)
        try mkdirp(artifacts)
        let results = Results()
        let group = DispatchGroup()
        for (i, shard) in shards.enumerated() where !shard.isEmpty {
            group.enter()
            let worker = Worker(index: i + 1, slot: slots[i], ws: ws, bundles: bundles, tests: shard, timeout: timeout,
                                artifacts: artifacts, results: results, device: device)
            Thread.detachNewThread {
                worker.run()
                group.leave()
            }
        }
        group.wait()
        // A few failures get one more run, alone on a quiet Mac: a timed gesture
        // or a wait can lose only because every host was busy.
        var passedAlone: [String] = []
        // Tests whose app never launched always run again (a host's whole
        // share can fail that way), the rest when there are few.
        let launchFailures = selected.filter { (results.failed[$0.user] ?? []).contains { $0.contains("could not launch the app") } }
        let others = selected.filter { results.failed[$0.user] != nil && !launchFailures.contains($0) }
        let failedIDs = launchFailures + (others.count <= 10 ? others : [])
        if !failedIDs.isEmpty {
            Log.step("running \(failedIDs.count) failed UI test(s) again, one per host, to rule out load")
            let again = Results()
            // One test per host at a time, the hosts side by side.
            let lanes = min(slots.count, failedIDs.count)
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                let mine = failedIDs.enumerated().filter { $0.offset % lanes == lane }.map(\.element)
                Worker(index: slots.count + 1 + lane, slot: slots[lane], ws: ws, bundles: bundles, tests: mine, timeout: timeout,
                       artifacts: artifacts, results: again, device: device).run()
            }
            for id in failedIDs where again.passed.contains(id.user) {
                results.recover(id.user)
                passedAlone.append(id.user)
            }
        }
        for slot in slots { Slots.terminateAll(slot) }

        // Report.
        let r = results
        for (id, reason) in r.crashed { print("  CRASHED: \(id): \(reason)") }
        for id in passedAlone { print("  flaky: \(id) failed while the run was busy, and passed alone (load, or a flaky test)") }
        let notRun = try saveResults(ws: ws, results: r, selected: selected.map(\.user) + missing + unmatched, marked: markedTests, load: passedAlone,
                                     excluded: excluded, unbuilt: unbuiltTests)
        var parts = ["\(r.passed.count) passed", "\(r.failed.count) failed"]
        if !r.skipped.isEmpty { parts.append("\(r.skipped.count) skipped") }
        if !markedTests.isEmpty { parts.append("\(markedTests.count) simulator-only (`simless test --simulator-only` lists them)") }
        if !r.crashed.isEmpty { parts.append("\(r.crashed.count) crashed") }
        if !passedAlone.isEmpty { parts.append("\(passedAlone.count) flaky") }
        if !notRun.isEmpty { parts.append("\(notRun.count) didn't run") }
        print(parts.joined(separator: ", "))
        for id in notRun.prefix(20) { print("  NOT RUN: \(id)") }
        if !unbuiltTests.isEmpty {
            let targets = Set(unbuiltTests.map { String($0.split(separator: "/")[0]) }).sorted()
            print("  note: \(targets.joined(separator: ", ")) isn't in the scheme's build, so its \(unbuiltTests.count) test(s) are listed as not built")
        }
        let ok = r.failed.isEmpty && r.crashed.isEmpty && notRun.isEmpty
        if !ok, let note = SimulatorBranches.note(ws) { print("  \(note)") }
        print("\(ok ? "PASSED" : "FAILED") in \(secs(t)) (screenshots of failures and logs: \(artifacts))")
        return ok
    }

    /// Why no UI test target can run: none is in the build, or simless found
    /// no sources for the ones that are.
    static func noTargetsError(_ ws: Workspace) -> SimlessError {
        let names = builtTargetNames(ws).sorted()
        if names.isEmpty { return SimlessError("no UI test targets in the build (is the UI test target in the scheme?)") }
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        return SimlessError("no UI test sources found:\n" + names.map {
            "  " + missingSourcesReason(target: $0, pbx: pbx, project: ws.config.project, projectDir: ws.projectDir,
                                         uiSources: ws.config.tests?.uiSources?[$0])
        }.joined(separator: "\n"))
    }

    /// Why one UI test target in the build has no source, and what to set.
    static func missingSourcesReason(target: String, pbx: String, project: String, projectDir: String, uiSources: String?) -> String {
        let setting = "set tests.uiSources in .simless.json to its folder, relative to the repository: {\"tests\": {\"uiSources\": {\"\(target)\": \"<folder>\"}}}"
        if let folder = uiSources { return "\(target): tests.uiSources names \(folder), which holds no Swift file" }
        let synced = PBX.synchronizedFolders(target: target, pbx: pbx)
        if !synced.isEmpty {
            return "\(target): no Swift file in its synchronized folders (\(synced.joined(separator: ", "))) or its Sources build phase in \(project); \(setting)"
        }
        return "\(target): no synchronized folder, no Swift file in its Sources build phase in \(project), and no folder \(projectDir)/\(target); \(setting)"
    }

    /// The error of a run with no filter that finds no test method.
    static func noTestsMessage(_ targets: [UITarget]) -> String {
        targets.map { t in
            let unknown = discover(t).unknownSuperclasses.map { "\($0.cls) inherits from \($0.superclass), which no file of \(t.name) declares" }
            return "found no test methods in \(t.name) (\(t.sources.count) Swift file(s)): simless looks for `func test...()` in classes "
                + "whose chain of superclasses, declared in these files, reaches XCTestCase, and in extensions of them"
                + (unknown.isEmpty ? "" : "; " + unknown.joined(separator: "; "))
        }.joined(separator: "\n")
    }

    /// UI hosts are light (about 1.5 GB each) and mostly wait on the app, so up to
    /// one per two cores.
    static var defaultJobs: Int { max(1, min(4, ProcessInfo.processInfo.processorCount / 2)) }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var passed: [String] = []
        private(set) var failed: [String: [String]] = [:]
        private(set) var skipped: [String: String] = [:]
        private(set) var crashed: [(String, String)] = []
        private(set) var seconds: [String: Double] = [:]
        func pass(_ id: String, _ s: Double) { lock.lock(); passed.append(id); seconds[id] = s; lock.unlock() }
        func fail(_ id: String, _ line: String) { lock.lock(); failed[id, default: []].append(line); lock.unlock() }
        func failedTest(_ id: String, _ s: Double) { lock.lock(); seconds[id] = s; if failed[id] == nil { failed[id] = ["failed"] }; lock.unlock() }
        func skip(_ id: String, _ why: String, _ s: Double) { lock.lock(); skipped[id] = why; seconds[id] = s; lock.unlock() }
        func crash(_ id: String, _ why: String) { lock.lock(); crashed.append((id, why)); lock.unlock() }
        /// A failure that didn't happen again alone.
        func recover(_ id: String) { lock.lock(); failed.removeValue(forKey: id); passed.append(id); lock.unlock() }
    }

    /// One xctest process driving one host, through its share of the tests.
    final class Worker: @unchecked Sendable {
        let index: Int, slot: SlotRecord, ws: Workspace, bundles: [String: String], tests: [TestID]
        let timeout: Double, artifacts: String, results: Results, device: String

        init(index: Int, slot: SlotRecord, ws: Workspace, bundles: [String: String], tests: [TestID], timeout: Double,
             artifacts: String, results: Results, device: String) {
            self.index = index; self.slot = slot; self.ws = ws; self.bundles = bundles; self.tests = tests
            self.timeout = timeout; self.artifacts = artifacts; self.results = results; self.device = device
        }

        func run() {
            var remaining = tests
            var attempts = 0
            while !remaining.isEmpty && attempts < 20 {
                attempts += 1
                let target = remaining[0].target
                let batch = remaining.filter { $0.target == target }
                let done = runBatch(batch, bundle: bundles[target] ?? "")
                remaining.removeAll { done.contains($0) }
            }
        }

        /// Runs tests until xctest exits; returns the tests that are finished
        /// (passed, failed, or the one that hung or crashed the runner).
        private func runBatch(_ batch: [TestID], bundle: String) -> Set<TestID> {
            var env = ProcessInfo.processInfo.environment
            // TEST_RUNNER_FOO reaches the tests as FOO, like with xcodebuild.
            for (k, v) in env where k.hasPrefix("TEST_RUNNER_") { env[String(k.dropFirst("TEST_RUNNER_".count))] = v }
            env["SIMLESS_UI_PORT"] = String(slot.port)
            env["SIMLESS_UI_APP"] = (try? RuntimeHost.installedApp(slot)) ?? ""
            env["SIMLESS_UI_SLOT"] = slot.slotID
            env["SIMLESS_UI_LOG"] = "\(artifacts)/host\(index).log"
            env["SIMLESS_UI_ARTIFACTS"] = artifacts
            let canvas = (try? Render.canvas(device)) ?? Render.canvases["iphone"]!
            env["SIMLESS_UI_CANVAS"] = "\(canvas.width),\(canvas.height),\(canvas.safeTop),\(canvas.safeBottom)"
            env["SIMLESS_UI_IDIOM"] = canvas.width < 600 ? "phone" : "pad"
            // The app's real launch, as XCUITest gives it: no SIMLESS_HEADLESS (apps
            // read it as "render host, skip side effects"); the runtime keeps it hidden.
            for (k, v) in RuntimeHost.baseEnvironment(slot) where k != "SIMLESS_HEADLESS" { env["SIMLESS_HOST_ENV_\(k)"] = v }
            if Native.isNative(slot) {
                // Started directly, not with `open`: the shim runs the app's executable.
                env["SIMLESS_UI_EXEC"] = (try? Native.executable(Native.app(slot))) ?? ""
            } else {
                env["SIMLESS_HOST_ENV_SIMLESS_SANDBOX_TOKENS"] = Sandbox.readToken(ws.root) ?? ""
            }
            env["SIMLESS_HOST_ENV_SIMLESS_DEVICE_MODEL"] = canvas.width < 600 ? "iPhone" : "iPad"

            let selection = batch.map(\.xctest).joined(separator: ",")
            let log = "\(artifacts)/runner\(index).log"
            var done = Set<TestID>()
            var current: (TestID, Double)?
            let byName = Dictionary(batch.map { ("\($0.cls)/\($0.method)", $0) }, uniquingKeysWith: { a, _ in a })
            let caseRe = try! NSRegularExpression(pattern: #"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)(?: \((\d+\.\d+) seconds\))?"#)
            let failRe = try! NSRegularExpression(pattern: #"^(.*?):(\d+): error: -\[(?:[\w.]+\.)?(\w+) (\w+)\] : (.*)$"#)
            let skipRe = try! NSRegularExpression(pattern: #"-\[(?:[\w.]+\.)?(\w+) (\w+)\] : Test skipped(?: - (.*))?$"#)
            var skipReasons: [String: String] = [:]
            let r = try? Shell.stream(["xcrun", "xctest", "-XCTest", selection, bundle], cwd: ws.root, logPath: log, env: env, onLine: { raw in
                let line = visibleText(raw)
                let range = NSRange(line.startIndex..., in: line)
                if let m = failRe.firstMatch(in: line, range: range), let f = Range(m.range(at: 1), in: line), let l = Range(m.range(at: 2), in: line),
                   let c = Range(m.range(at: 3), in: line), let t = Range(m.range(at: 4), in: line), let msg = Range(m.range(at: 5), in: line),
                   let id = byName["\(line[c])/\(line[t])"] {
                    let text = "\((String(line[f]) as NSString).lastPathComponent):\(line[l]): \(line[msg])"
                    self.results.fail(id.user, text)
                    print("  \(id.user): \(text)")
                    fflush(stdout)
                }
                if let m = skipRe.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line) {
                    skipReasons["\(line[c])/\(line[t])"] = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? "skipped"
                }
                if let m = caseRe.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line),
                   let t = Range(m.range(at: 2), in: line), let e = Range(m.range(at: 3), in: line), let id = byName["\(line[c])/\(line[t])"] {
                    let secs = Range(m.range(at: 4), in: line).flatMap { Double(line[$0]) } ?? 0
                    switch line[e] {
                    case "started": current = (id, now())
                    case "passed": self.results.pass(id.user, secs); done.insert(id); current = nil
                    case "failed": self.results.failedTest(id.user, secs); done.insert(id); current = nil
                    default:
                        self.results.skip(id.user, skipReasons["\(id.cls)/\(id.method)"] ?? "skipped", secs)
                        done.insert(id); current = nil
                    }
                }
            }, tick: {
                if let (id, start) = current, now() - start > self.timeout {
                    self.results.crash(id.user, "ran past the \(Int(self.timeout)) s time limit")
                    done.insert(id)
                    current = nil
                    Slots.terminateAll(self.slot)
                    return false
                }
                return true
            })
            if let (id, _) = current {
                // xctest exited in the middle of a test: the runner itself crashed.
                let why = (r?.out.split(separator: "\n").suffix(3).joined(separator: " ")).map { String($0.prefix(300)) } ?? "the test runner exited"
                results.crash(id.user, why)
                done.insert(id)
            }
            // Tests xctest never got to (it exited early) stay for the next attempt.
            if done.isEmpty { done = Set(batch) }
            return done
        }
    }

    // MARK: - Results

    static func loadDurations(_ ws: Workspace) -> [String: Double] {
        guard let d = FileManager.default.contents(atPath: "\(ws.work)/ui-test-results.json"),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return r["seconds"] as? [String: Double] ?? [:]
    }

    /// Writes ui-test-results.json; returns the selected tests that never ran.
    @discardableResult
    static func saveResults(ws: Workspace, results r: Results, selected: [String], marked: [String: String], load: [String],
                            excluded: [String], unbuilt: [String]) throws -> [String] {
        // Every test, with what happened to it.
        var tests: [String: [String: Any]] = [:]
        for (id, reason) in marked { tests[id] = ["status": "simulator-only", "reason": reason] }
        for id in excluded { tests[id] = ["status": "excluded", "reason": "--skip or tests.skip"] }
        for id in unbuilt { tests[id] = ["status": "not-built", "reason": "its target isn't in the scheme's build"] }
        for id in r.passed {
            tests[id] = load.contains(id) ? ["status": "flaky", "reason": "failed in the full run, passed when run again alone"] : ["status": "passed"]
        }
        for (id, lines) in r.failed { tests[id] = ["status": "failed", "issues": lines] }
        for (id, reason) in r.skipped { tests[id] = ["status": TestEngine.isSimulatorOnly(reason) ? "simulator-only" : "skipped", "reason": reason] }
        for (id, reason) in r.crashed { tests[id] = ["status": "crashed", "reason": reason] }
        for (id, seconds) in r.seconds { tests[id]?["seconds"] = (seconds * 1000).rounded() / 1000 }
        let notRun = selected.filter { tests[$0] == nil }.sorted()
        for id in notRun { tests[id] = ["status": "not-run", "reason": "selected, but it never ran"] }
        let ok = r.failed.isEmpty && r.crashed.isEmpty && notRun.isEmpty
        let out: [String: Any] = ["ok": ok, "selected": selected.count, "notRun": notRun, "flaky": load.sorted(),
                                  "passed": r.passed.sorted(), "failed": r.failed, "skipped": r.skipped,
                                  "crashed": r.crashed.map { ["test": $0.0, "reason": $0.1] }, "seconds": r.seconds,
                                  "simulatorOnly": marked, "tests": tests]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/ui-test-results.json"))
        return notRun
    }
}
