// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Fixtures nobody has to write. `root` is the app's first window, as its
/// `@main` App builds it, and every `#Preview` block (and `PreviewProvider`)
/// is a fixture named `<File>.<preview name or number>`.
///
/// They compile at `simless up` into a dylib of their own, the way a hot-reload
/// patch does, from copies of the files they're in: each preview becomes a
/// function that registers it, in place, so the copy keeps its line numbers and
/// the file's private helpers and sample data. Everything else in the copy is
/// blanked and resolves to the app's own code. `root` turns the App into a view
/// with the App's properties (its `@StateObject`s, say) and the first
/// `WindowGroup`'s content as its body, plus the scene modifiers that views have
/// too (`.modelContainer`, `.environment`, `.environmentObject`).
///
/// A preview that doesn't compile (it needs something only a scene has, or a
/// form this doesn't read) is left out with the compiler's reason, and the rest
/// compile again without it.
enum Previews {
    struct Entry: Codable {
        var name: String
        var file: String
        var line: Int
        var skipped: String?
        /// True for `root`, an App's first window.
        var app: Bool? = nil
    }

    struct Manifest: Codable {
        var dylib: String?
        var entries: [Entry]
        /// Why the previews have no library although some weren't left out.
        var failure: String?
    }

    static func dir(_ ws: Workspace) -> String { "\(ws.work)/previews" }
    static func manifestPath(_ ws: Workspace) -> String { "\(dir(ws))/previews.json" }

    static func manifest(_ ws: Workspace) -> Manifest? {
        FileManager.default.contents(atPath: manifestPath(ws)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    /// Helpers the generated code calls, in the entry file of the previews'
    /// dylib and of a hot-reload patch that compiles previews.
    static let helpers = """
        import SwiftUI
        import UIKit

        @MainActor func simlessPreviewContent<V: View>(@ViewBuilder _ make: () -> V) -> AnyView { AnyView(make()) }
        // UIKit previews return a view controller or a view. Disfavored, so a body
        // that could be read either way (a `let` and an `if`) is a SwiftUI view.
        @_disfavoredOverload @MainActor func simlessPreviewContent(_ make: () -> UIViewController) -> AnyView { AnyView(SimlessPreviewController(controller: make())) }
        @_disfavoredOverload @MainActor func simlessPreviewContent(_ make: () -> UIView) -> AnyView { AnyView(SimlessPreviewUIView(view: make())) }

        struct SimlessPreviewController: UIViewControllerRepresentable {
            let controller: UIViewController
            func makeUIViewController(context: Context) -> UIViewController { controller }
            func updateUIViewController(_ controller: UIViewController, context: Context) {}
        }

        struct SimlessPreviewUIView: UIViewRepresentable {
            let view: UIView
            func makeUIView(context: Context) -> UIView { view }
            func updateUIView(_ view: UIView, context: Context) {}
        }

        /// The App's `@UIApplicationDelegateAdaptor`, for `root`.
        @MainActor func simlessAppDelegate<D: NSObject>(_ type: D.Type) -> D { (UIApplication.shared.delegate as? D) ?? type.init() }
        """

    /// Only in the previews' dylib: one class of this name per process.
    static let registrations = """
        /// Registers them into a registry a hot-reload patch made.
        @objc(SimlessPreviewRegistrations) nonisolated public final class SimlessPreviewRegistrations: NSObject {
            @objc public static func registerInto(_ address: NSNumber) {
                let a = address.intValue
                MainActor.assumeIsolated {
                    simlessRegisterPreviews(Unmanaged<SimlessRegistry>.fromOpaque(UnsafeRawPointer(bitPattern: a)!).takeUnretainedValue())
                }
            }
        }
        """

    // MARK: - Generating

    struct Generated {
        var texts: [String: String] = [:]   // file -> what the dylib compiles of it
        var entries: [Entry] = []
        var calls: [String] = []            // registration functions, in order
        var ranges: [String: [(entry: Int, lines: ClosedRange<Int>)]] = [:]
        var clashes: [NameClash] = []       // names that two entries still share
    }

    /// Two entries that still share a name after `distinctNames`.
    struct NameClash: Error, CustomStringConvertible {
        let name: String
        let description: String
    }

    /// A preview or root by its file and its name: what a compile error
    /// leaves out, so an error in one file never leaves out an entry of another.
    struct Key: Hashable {
        var file: String
        var name: String
    }

    /// An entry as the scan finds it: `root` for a `@main` App,
    /// `<File>.<preview name or number>` for a preview. `counts` is false for
    /// one that is never generated (in a local package).
    struct Scanned {
        var file: String
        var name: String
        var isApp: Bool
        var counts: Bool
    }

    /// The names of `scanned`, by index, made distinct. Only entries that count
    /// take part, all of them whether they compile or not, so a name never
    /// changes when another entry starts or stops compiling:
    /// - Apps that share a name are each `<File>.root`.
    /// - Previews in two or more files that share a name are each
    ///   `<folder>.<name>`, the folder the file is in.
    /// - Previews in one file that share a name: the first keeps it, the next
    ///   are `<name>.2`, `<name>.3`.
    /// Names still shared after that are clashes, with paths relative to `root`.
    static func distinctNames(_ scanned: [Scanned], root: String) -> (names: [String], clashes: [NameClash]) {
        var names = scanned.map(\.name)
        let counted = scanned.indices.filter { scanned[$0].counts }
        func base(_ f: String) -> String { ((f as NSString).lastPathComponent as NSString).deletingPathExtension }
        func folder(_ f: String) -> String { ((f as NSString).deletingLastPathComponent as NSString).lastPathComponent }
        for (name, all) in Dictionary(grouping: counted, by: { scanned[$0].name }) where all.count > 1 {
            let apps = all.filter { scanned[$0].isApp }, previews = all.filter { !scanned[$0].isApp }
            if apps.count > 1 { for i in apps { names[i] = "\(base(scanned[i].file)).\(name)" } }
            guard previews.count > 1 else { continue }
            let files = Set(previews.map { scanned[$0].file })
            var inFile: [String: Int] = [:]
            for i in previews.sorted() {
                let f = scanned[i].file
                inFile[f, default: 0] += 1
                names[i] = (files.count > 1 ? "\(folder(f))." : "") + name + (inFile[f]! > 1 ? ".\(inFile[f]!)" : "")
            }
        }
        func relative(_ f: String) -> String { f.hasPrefix(root + "/") ? String(f.dropFirst(root.count + 1)) : f }
        var first: [String: Int] = [:]
        var clashes: [NameClash] = []
        for i in counted {
            guard let j = first[names[i]] else { first[names[i]] = i; continue }
            let (a, b) = (scanned[j], scanned[i])
            let why: String
            if a.isApp && b.isApp {
                why = "\(relative(a.file)) and \(relative(b.file)) each have an @main App; rename one of the files (their fixtures would both be \(names[i]))"
            } else if !a.isApp && !b.isApp && a.name == b.name {
                why = "\(relative(a.file)) and \(relative(b.file)) both have a preview named \(a.name); rename one preview, or one of their folders (their fixtures would both be \(names[i]))"
            } else {
                let preview = b.isApp ? a : b
                why = "\(relative(a.file)) and \(relative(b.file)) both give a fixture named \(names[i]); rename the preview in \(relative(preview.file))"
            }
            clashes.append(NameClash(name: names[i], description: why))
        }
        return (names, clashes)
    }

    /// Why `simless up` can't name its fixtures, before it builds anything.
    static func checkNames(_ ws: Workspace) throws {
        let input = input(ws)
        if let clash = scan(input, graph: PatchScope.graph(input)).clashes.first { throw SimlessError("the fixtures can't be named: \(clash)") }
    }

    private struct Found {
        var entry: Entry
        var chunk: Int
        var span: ClosedRange<Int>
        var fn: String
        var make: (String) -> Result<String, SimlessError>
    }

    /// Every preview and App in `input`, with its distinct name, in order: the
    /// App's file first, so `root` comes before the previews, then by path.
    private static func scan(_ input: PatchScope.Input, graph g: PatchScope.Graph) -> (found: [Found], clashes: [NameClash]) {
        let files = input.sources.keys.sorted { a, b in
            let (ma, mb) = (input.sources[a]!.contains("@main"), input.sources[b]!.contains("@main"))
            return ma != mb ? ma : a < b
        }
        var found: [Found] = []
        for file in files {
            guard let text = input.sources[file], let cs = g.chunksByFile[file] else { continue }
            let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            var number = 0
            for (i, c) in cs.enumerated() {
                let isPreview = c.kind == .preview || (c.kind == .type && c.inherits.contains("PreviewProvider"))
                let isApp = c.kind == .type && c.inherits.contains("App") && c.text.contains("@main")
                guard isPreview || isApp else { continue }
                if isPreview { number += 1 }
                let line = 1 + (text as NSString).substring(to: c.start).filter { $0 == "\n" }.count
                let span = line...(line + c.text.filter { $0 == "\n" }.count)
                let fn = "simlessPreview\(found.count + 1)"
                let name: String
                let make: (String) -> Result<String, SimlessError>
                if isApp {
                    name = "root"
                    make = { root(c.text, name: $0, fn: fn) }
                } else if c.kind == .type {
                    name = "\(base).\(c.name)"
                    make = { provider(c.text, type: c.name, name: $0, fn: fn) }
                } else {
                    name = "\(base).\(previewLabel(c.text) ?? String(number))"
                    make = { preview(c.text, name: $0, fn: fn) }
                }
                found.append(Found(entry: Entry(name: name, file: file, line: line, app: isApp ? true : nil), chunk: i, span: span, fn: fn, make: make))
            }
        }
        let scanned = found.map { Scanned(file: $0.entry.file, name: $0.entry.name, isApp: $0.entry.app == true, counts: !inPackage(input, $0.entry.file)) }
        let (names, clashes) = distinctNames(scanned, root: input.root)
        for i in found.indices { found[i].entry.name = names[i] }
        return (found, clashes)
    }

    private static func inPackage(_ input: PatchScope.Input, _ file: String) -> Bool {
        input.moduleOf[file].map { $0 != input.appModule } == true
    }

    /// The registration code for every preview and the root, leaving out
    /// `skip`, or only for `only`, keeping `keepAlso`'s chunks of each file too.
    /// Names are `scan`'s; `clashes` lists the ones still shared.
    static func generate(_ input: PatchScope.Input, skip: [Key: String], only: Set<String>? = nil,
                         keepAlso: [String: Set<Int>] = [:]) -> Generated {
        let g = PatchScope.graph(input)
        var out = Generated()
        let (found, clashes) = scan(input, graph: g)
        out.clashes = clashes
        let files = found.map(\.entry.file).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        for file in files {
            guard let text = input.sources[file], let cs = g.chunksByFile[file], let keys = g.nodeOf[file], let first = cs.first else { continue }
            var replaced: [Int: String] = [:]
            for f in found where f.entry.file == file {
                if let only, !only.contains(f.entry.name) { continue }
                var entry = f.entry
                let made: Result<String, SimlessError> = inPackage(input, file)
                    ? .failure(SimlessError("it's in a local package; only the app target's previews are generated"))
                    : skip[Key(file: file, name: entry.name)].map { .failure(SimlessError($0)) } ?? f.make(entry.name)
                switch made {
                case .success(let code):
                    replaced[f.chunk] = code
                    out.calls.append(f.fn)
                    out.ranges[file, default: []].append((out.entries.count, f.span))
                case .failure(let why):
                    entry.skipped = why.description
                }
                out.entries.append(entry)
            }
            guard !replaced.isEmpty else { continue }
            // The file's private declarations the generated code uses stay; the
            // rest is blanked and resolves to the app's own.
            var keep = Set(replaced.keys).union(keepAlso[file] ?? [])
            var grew = true
            while grew {
                grew = false
                for i in cs.indices where !keep.contains(i) {
                    guard let k = keys[cs[i].key], let n = g.nodes[k], k.hasPrefix("\(file)#"), n.external ? cs[i].isPrivate : true else { continue }
                    if keep.contains(where: { g.deps[keys[cs[$0].key] ?? ""]?.contains(k) == true }) { keep.insert(i); grew = true }
                }
            }
            var copy = (text as NSString).substring(to: first.start)
            for (i, c) in cs.enumerated() { copy += replaced[i] ?? (keep.contains(i) ? c.text : PatchScope.blank(c.text)) }
            out.texts[file] = copy
        }
        return out
    }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func newlines(_ s: Substring) -> String { String(repeating: "\n", count: s.filter { $0 == "\n" }.count) }

    /// The index after the brace that closes the one at `open` (in code text).
    private static func closing(_ u: [UInt16], from open: Int) -> Int? {
        var depth = 0
        for j in open..<u.count {
            if u[j] == 123 { depth += 1 } else if u[j] == 125 { depth -= 1; if depth == 0 { return j } }
        }
        return nil
    }

    private static func skipSpace(_ u: [UInt16], _ i: Int) -> Int {
        var i = i
        while i < u.count, [32, 9, 10, 13].contains(u[i]) { i += 1 }
        return i
    }

    /// After `(` at `open`, the index of its `)`.
    private static func closingParen(_ u: [UInt16], from open: Int) -> Int? {
        var depth = 0
        for j in open..<u.count {
            if u[j] == 40 { depth += 1 } else if u[j] == 41 { depth -= 1; if depth == 0 { return j } }
        }
        return nil
    }

    static func previewLabel(_ text: String) -> String? {
        let clean = PatchScope.code(text), u = Array(clean.utf16), ns = text as NSString
        let r = (clean as NSString).range(of: "#Preview")
        let at = r.location + r.length
        guard r.location != NSNotFound, at < u.count, u[at] == 40, let close = closingParen(u, from: at) else { return nil }
        let args = ns.substring(with: NSRange(location: at + 1, length: close - at - 1))
        guard let m = args.range(of: #"^\s*"((?:\\.|[^"\\])*)""#, options: .regularExpression) else { return nil }
        return String(args[m].drop { $0 != "\"" }.dropFirst().dropLast())
    }

    /// `#Preview("Name", traits: …) { body }` as a function that registers the body.
    static func preview(_ text: String, name: String, fn: String) -> Result<String, SimlessError> {
        let clean = PatchScope.code(text), u = Array(clean.utf16), ns = text as NSString
        let start = (clean as NSString).range(of: "#Preview").location
        guard start != NSNotFound else { return .failure(SimlessError("no #Preview")) }
        var i = start + 8
        if i < u.count, u[i] == 40 {
            guard let close = closingParen(u, from: i) else { return .failure(SimlessError("unbalanced #Preview arguments")) }
            let args = ns.substring(with: NSRange(location: i, length: close - i))
            if args.range(of: #"\bas\s*:"#, options: .regularExpression) != nil {
                return .failure(SimlessError("a widget or Live Activity preview, not a view"))
            }
            i = close + 1
        }
        i = skipSpace(u, i)
        guard i < u.count, u[i] == 123, let end = closing(u, from: i) else {
            return .failure(SimlessError("a #Preview without a trailing closure, which this doesn't read"))
        }
        let header = Substring(ns.substring(with: NSRange(location: start, length: i + 1 - start)))
        let body = ns.substring(with: NSRange(location: i + 1, length: end - i - 1))
        let tail = ns.substring(from: end + 1)
        let before = ns.substring(to: start)
        let lines = body.components(separatedBy: "\n")
        let previewable = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@Previewable") }
        if !previewable {
            return .success(before + "@MainActor func \(fn)(_ r: SimlessRegistry) { r.add(\(literal(name))) { simlessPreviewContent {"
                            + newlines(header) + body + "} } }" + tail)
        }
        // `@Previewable` state becomes a view's state, as the macro does it.
        var out: [String] = [], opened = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("@Previewable") {
                out.append(line.replacingOccurrences(of: "@Previewable ", with: "").replacingOccurrences(of: "@Previewable", with: ""))
            } else if !opened, !t.isEmpty, !t.hasPrefix("//") {
                out.append("var body: some View { " + line); opened = true
            } else {
                out.append(line)
            }
        }
        if !opened { return .failure(SimlessError("a #Preview with only @Previewable state")) }
        let view = "SimlessPreviewView\(fn.dropFirst("simlessPreview".count))"
        return .success(before + "private struct \(view): View {" + newlines(header) + out.joined(separator: "\n")
                        + "} }; @MainActor func \(fn)(_ r: SimlessRegistry) { r.add(\(literal(name))) { \(view)() } }" + tail)
    }

    /// A `PreviewProvider` type, with a function that registers its previews after it.
    static func provider(_ text: String, type: String, name: String, fn: String) -> Result<String, SimlessError> {
        let clean = PatchScope.code(text), u = Array(clean.utf16), ns = text as NSString
        guard let open = u.firstIndex(of: 123), let end = closing(u, from: open) else { return .failure(SimlessError("unbalanced braces")) }
        return .success(ns.substring(to: end + 1) + "; @MainActor func \(fn)(_ r: SimlessRegistry) { r.add(\(literal(name))) { \(type).previews } }"
                        + ns.substring(from: end + 1))
    }

    /// Scene modifiers that views have too, kept on `root`'s content.
    private static let viewModifiers: Set<String> = ["modelContainer", "environment", "environmentObject", "defaultAppStorage", "modelContext"]

    /// The `@main` App as a view: its properties, and its first WindowGroup's
    /// content as the body.
    static func root(_ text: String, name: String, fn: String) -> Result<String, SimlessError> {
        var text = text
        // The delegate adaptor only works in an App: read the app's delegate instead.
        let adaptor = try! NSRegularExpression(pattern: #"@UIApplicationDelegateAdaptor\(\s*([A-Za-z_][\w.]*)\.self\s*\)\s*((?:(?:private|fileprivate|internal|public)\s+)?)var\s+(\w+)(\s*:\s*[\w.]+)?"#)
        let full = NSRange(location: 0, length: (text as NSString).length)
        text = adaptor.stringByReplacingMatches(in: text, range: full, withTemplate: "$2var $3: $1 { simlessAppDelegate($1.self) }")
        let clean = PatchScope.code(text), u = Array(clean.utf16), ns = text as NSString
        guard let open = u.firstIndex(of: 123), let end = closing(u, from: open) else { return .failure(SimlessError("unbalanced braces in the App")) }
        func find(_ pattern: String, from: Int = 0, to: Int? = nil) -> NSRange? {
            let re = try! NSRegularExpression(pattern: pattern)
            let r = re.firstMatch(in: clean, range: NSRange(location: from, length: (to ?? u.count) - from))
            return r?.range
        }
        // body: some Scene { … WindowGroup(…) { content } .modifiers … }
        guard let bodyDecl = find(#"\bvar\s+body\s*:\s*some\s+Scene\s*\{"#, from: open, to: end),
              let bodyEnd = closing(u, from: NSMaxRange(bodyDecl) - 1) else {
            return .failure(SimlessError("the App has no `var body: some Scene`"))
        }
        guard let group = find(#"\bWindowGroup\b"#, from: NSMaxRange(bodyDecl), to: bodyEnd) else {
            return .failure(SimlessError("the App's body has no WindowGroup"))
        }
        var i = NSMaxRange(group)
        i = skipSpace(u, i)
        if i < u.count, u[i] == 40, let close = closingParen(u, from: i) { i = skipSpace(u, close + 1) }
        guard i < u.count, u[i] == 123, let contentEnd = closing(u, from: i) else {
            return .failure(SimlessError("the App's WindowGroup has no trailing closure"))
        }
        let content = ns.substring(with: NSRange(location: i + 1, length: contentEnd - i - 1))
        // Modifiers on the scene that views have too.
        var kept: [String] = []
        var j = contentEnd + 1
        while true {
            let k = skipSpace(u, j)
            guard k < u.count, u[k] == 46 else { break }
            var e = k + 1
            while e < u.count, let c = Unicode.Scalar(u[e]), CharacterSet.alphanumerics.contains(c) || c == "_" { e += 1 }
            let name = ns.substring(with: NSRange(location: k + 1, length: e - k - 1))
            var after = e
            if after < u.count, u[after] == 40, let close = closingParen(u, from: after) { after = close + 1 }
            let t = skipSpace(u, after)
            if t < u.count, u[t] == 123, let close = closing(u, from: t) { after = close + 1 }
            if viewModifiers.contains(name) { kept.append(ns.substring(with: NSRange(location: k, length: after - k))) }
            j = after
        }
        let newBody = "var body: some View { Group {" + content + "}" + kept.joined() + " }"
        let oldBody = ns.substring(with: NSRange(location: bodyDecl.location, length: bodyEnd + 1 - bodyDecl.location))
        let pad = max(0, oldBody.filter { $0 == "\n" }.count - newBody.filter { $0 == "\n" }.count)
        var inner = ns.substring(with: NSRange(location: open + 1, length: bodyDecl.location - open - 1)) + newBody
            + String(repeating: "\n", count: pad) + ns.substring(with: NSRange(location: bodyEnd + 1, length: end - bodyEnd - 1))
        // The App's init runs once, in the app; the view doesn't repeat it.
        let innerClean = PatchScope.code(inner), iu = Array(innerClean.utf16)
        if let m = try! NSRegularExpression(pattern: #"(?m)^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public)\s+)?init\s*\(\s*\)\s*\{"#)
            .firstMatch(in: innerClean, range: NSRange(location: 0, length: iu.count)),
           let close = closing(iu, from: NSMaxRange(m.range) - 1) {
            let r = NSRange(location: m.range.location, length: close + 1 - m.range.location)
            inner = (inner as NSString).replacingCharacters(in: r, with: PatchScope.blank((inner as NSString).substring(with: r)))
        }
        let header = ns.substring(to: open + 1)
        let view = "SimlessRootView\(fn.dropFirst("simlessPreview".count))"
        return .success("struct \(view): View {" + newlines(Substring(header)) + inner
                        + "}; @MainActor func \(fn)(_ r: SimlessRegistry) { if !r.names.contains(\(literal(name))) { r.add(\(literal(name))) { \(view)() } } }"
                        + ns.substring(from: end + 1))
    }

    // MARK: - Building and loading

    /// The files previews and `root` come from: those with a `#Preview`, a
    /// `PreviewProvider` or `@main`.
    private static func input(_ ws: Workspace) -> PatchScope.Input {
        var input = PatchScope.input(ws: ws, edited: [])
        input.sources = ws.config.previews == false ? [:]
            : input.sources.filter { $0.value.contains("#Preview") || $0.value.contains("PreviewProvider") || $0.value.contains("@main") }
        return input
    }

    /// Compiles the previews and root for the current build. Previews that
    /// don't compile are left out with the reason, a few rounds at most. If
    /// the last round still fails, the manifest is saved with the reasons
    /// and the build throws. A build without SimlessKit gets its fixtures only
    /// from this dylib, so it is built for it even with no preview, or with
    /// `"previews": false`.
    @discardableResult
    static func build(ws: Workspace, slot: SlotRecord, settings: Workspace.Settings) throws -> Manifest {
        let t = now()
        let d = dir(ws)
        try? FileManager.default.removeItem(atPath: d)
        try mkdirp(d)
        let m = try compileLeavingOut(input(ws), alwaysBuild: !slot.kitInBuild) { gen, prelude in
            try Patch.compile(ws: ws, slot: slot, settings: settings, files: gen.texts.keys.sorted(), texts: gen.texts,
                              name: "SimlessPreviews", dir: d, prelude: prelude, entry: "        simlessRegisterPreviews(r)",
                              forNewBuild: true)
        }
        try save(ws, m)
        if let failure = m.failure { throw SimlessError(failure) }
        if m.dylib != nil, !m.entries.isEmpty {
            let made = m.entries.filter { $0.skipped == nil }.count
            Log.step("previews: \(made) fixture(s) from #Preview\(m.entries.contains { $0.app == true && $0.skipped == nil } ? " and the App" : "") in \(secs(t))")
        }
        return m
    }

    /// Compiles the generated previews with `compile`, which gets them and the
    /// prelude and returns the library. Each failed round leaves out the
    /// previews its errors are in. If a round still fails after `rounds`, the
    /// manifest has no library and says why in `failure`. With no preview
    /// left, there is no library unless `alwaysBuild` (the fixtures alone,
    /// also when the last round left out the last preview).
    static func compileLeavingOut(_ input: PatchScope.Input, rounds: Int = 5, alwaysBuild: Bool = false,
                                  compile: (Generated, String) throws -> String) throws -> Manifest {
        var skip: [Key: String] = [:]
        var lastError: SimlessError?
        func prelude(_ gen: Generated) -> String {
            let calls = gen.calls.map { "    \($0)(r)" }.joined(separator: "\n")
            return helpers + "\n" + registrations + "\n\n@MainActor func simlessRegisterPreviews(_ r: SimlessRegistry) {\n\(calls)\n}\n"
        }
        func key(_ e: Entry) -> Key { Key(file: e.file, name: e.name) }
        func firstError(_ error: SimlessError?) -> String {
            (error?.description.split(separator: "\n").first { $0.contains("error:") } ?? "").trimmingCharacters(in: .whitespaces)
        }
        for _ in 0..<rounds {
            let gen = generate(input, skip: skip)
            if let clash = gen.clashes.first { throw clash }
            guard !gen.calls.isEmpty || alwaysBuild else { return Manifest(dylib: nil, entries: gen.entries) }
            do {
                return Manifest(dylib: try compile(gen, prelude(gen)), entries: gen.entries)
            } catch let error as SimlessError where error.description.hasPrefix("patch compile failed") {
                // Leave out the previews the errors are in; an error elsewhere in
                // a file (a helper it keeps) leaves out the file's previews.
                var blamed = 0
                for line in error.description.split(separator: "\n") {
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 4)
                    guard parts.count >= 5, let n = Int(parts[1]) else { continue }
                    let file = String(parts[0])
                    let message = parts[4].trimmingCharacters(in: .whitespaces)
                    let inFile = gen.ranges[file] ?? []
                    let hit = inFile.filter { $0.lines.contains(n) }
                    for (e, _) in hit.isEmpty ? inFile : hit where skip[key(gen.entries[e])] == nil {
                        skip[key(gen.entries[e])] = "doesn't compile outside Xcode's previews: \(message)"
                        blamed += 1
                    }
                }
                if blamed == 0 { throw error }
                lastError = error
            }
        }
        // The last round can leave out every preview that remained.
        let gen = generate(input, skip: skip)
        guard !gen.calls.isEmpty else {
            guard alwaysBuild else { return Manifest(dylib: nil, entries: gen.entries) }
            // A build without the kit has its fixtures only in this library:
            // build it with the fixtures alone.
            do {
                return Manifest(dylib: try compile(gen, prelude(gen)), entries: gen.entries)
            } catch let error as SimlessError where error.description.hasPrefix("patch compile failed") {
                return Manifest(dylib: nil, entries: gen.entries,
                                failure: "every preview was left out for compile errors (\(skip.count)), and the fixtures alone don't compile either; \(firstError(error))")
            }
        }
        return Manifest(dylib: nil, entries: gen.entries,
                        failure: "previews still don't compile after \(rounds) rounds (\(skip.count) left out for compile errors); \(firstError(lastError))")
    }

    /// For a hot reload that renders previews: their files as the patch
    /// compiles them (with what the patch keeps of them anyway), and the
    /// registrations to run after the build's.
    static func patchCode(ws: Workspace, names: [String], kept: [String: Set<Int>], texts: [String: String]) throws
        -> (texts: [String: String], prelude: String, entry: String) {
        try patchCode(input(ws), manifest: manifest(ws), names: names, kept: kept, texts: texts)
    }

    /// It generates from every file the build did, with what the build left
    /// out, so each name is the build's. A clash of a name not asked for
    /// doesn't stop it. A name asked for that the sources no longer give
    /// (changed since `simless up`) does.
    static func patchCode(_ input: PatchScope.Input, manifest: Manifest?, names: [String], kept: [String: Set<Int>],
                          texts: [String: String]) throws -> (texts: [String: String], prelude: String, entry: String) {
        let skip = Dictionary((manifest?.entries ?? []).compactMap { e in e.skipped.map { (Key(file: e.file, name: e.name), $0) } },
                              uniquingKeysWith: { a, _ in a })
        let gen = generate(input, skip: skip, only: Set(names), keepAlso: kept)
        if let clash = gen.clashes.first(where: { names.contains($0.name) }) { throw clash }
        let made = Set(gen.entries.map(\.name))
        if let missing = names.first(where: { !made.contains($0) }) {
            throw SimlessError("\(missing) isn't a preview of the current sources (the names changed since simless up); run simless up")
        }
        let calls = gen.calls.map { "        \($0)(r)" }.joined(separator: "\n")
        return (texts.merging(gen.texts) { $1 }, helpers, Patch.registerPreviews + "\n" + calls)
    }

    private static func save(_ ws: Workspace, _ m: Manifest) throws {
        try JSONEncoder().encode(m).write(to: URL(fileURLWithPath: manifestPath(ws)))
    }

    /// Loads the previews into a host that just started (before the newest
    /// hot-reload patch, whose entry registers them again). Returns why the
    /// host has no previews dylib, if it has none.
    @discardableResult
    static func load(_ slot: SlotRecord) -> String? {
        guard let ws = try? Workspace.load(at: slot.worktree), let m = manifest(ws) else { return "no previews were built" }
        guard let dylib = m.dylib, exists(dylib) else { return m.failure ?? "the previews build made no library" }
        // Once per host process: `up` and the launch it does may both get here.
        let marker = "\(slot.dir)/previews-loaded", mine = "\(slot.stats()?["pid"] ?? 0) \(dylib)"
        if (try? String(contentsOfFile: marker, encoding: .utf8)) == mine { return nil }
        // The host deletes what it loads: hand it a copy.
        let copy = "\(dir(ws))/load-\(UUID().uuidString.prefix(8)).dylib"
        guard (try? FileManager.default.copyItem(atPath: dylib, toPath: copy)) != nil else { return "could not copy \(dylib)" }
        defer { try? FileManager.default.removeItem(atPath: copy) }
        do {
            if let why = try Patch.live(dylib: copy, slot: slot) {
                Log.info("  note: fixtures from #Preview blocks not loaded (\(why))")
                return why
            }
            try? mine.write(toFile: marker, atomically: true, encoding: .utf8)
            return nil
        } catch {
            Log.info("  note: fixtures from #Preview blocks not loaded (\(error))")
            return "\(error)"
        }
    }

    /// One line for `simless up`: what was generated and what was left out.
    static func summary(_ ws: Workspace) -> String? {
        manifest(ws).flatMap { summary($0, root: ws.root, manifestPath: manifestPath(ws)) }
    }

    /// An entry left out whose name another entry has too is named with its
    /// file, relative to `root`.
    static func summary(_ m: Manifest, root: String, manifestPath: String) -> String? {
        guard !m.entries.isEmpty else { return nil }
        let skipped = m.entries.filter { $0.skipped != nil }
        let made = m.dylib == nil ? 0 : m.entries.count - skipped.count
        let shared = Set(Dictionary(grouping: m.entries, by: \.name).filter { $0.value.count > 1 }.keys)
        func label(_ e: Entry) -> String {
            guard shared.contains(e.name) else { return e.name }
            return "\(e.name) in \(e.file.hasPrefix(root + "/") ? String(e.file.dropFirst(root.count + 1)) : e.file)"
        }
        var s = "previews: \(made) of \(m.entries.count) generated"
        if !skipped.isEmpty {
            s += "; left out: " + skipped.prefix(5).map { "\(label($0)) (\($0.skipped!))" }.joined(separator: "; ")
            if skipped.count > 5 { s += "; +\(skipped.count - 5) more in \(manifestPath)" }
        }
        return s
    }
}
