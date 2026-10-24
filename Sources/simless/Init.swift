// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

// What `simless init` writes and removes. Outside main.swift: a global there
// is set by its top-level code, which the tests never run.

func writeConfig(_ config: Config, to path: String) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(config).write(to: URL(fileURLWithPath: path))
}

/// The files `simless init` writes and removes in `root`. It writes
/// `.simless.json` from `fresh`, unless the file is there and `force` is off.
/// With no `kitDir` in `fresh`, a fresh file keeps the old one's, so the
/// fixtures file stays where it is. Then it removes the kit and the App hook
/// that older inits wrote (`removeKit`). Returns the config in effect, whether
/// the old file was kept, and a line for each file removed or left.
func initFiles(root: String, force: Bool, fresh: Config) throws -> (config: Config, kept: Bool, removed: [String]) {
    let path = "\(root)/\(Workspace.configName)"
    // A file that doesn't load stops init, unless `force` replaces it.
    let previous = !exists(path) ? nil : force ? (try? Workspace.load(at: root))?.config : try Workspace.load(at: root).config
    let kept = previous != nil && !force
    var config = fresh
    if config.kitDir == nil { config.kitDir = previous?.kitDir }
    if kept, let previous { config = previous } else { try writeConfig(config, to: path) }
    return (config, kept, try removeKit(root: root, config: previous ?? config))
}

/// A line in the first comment of every SimlessKit.swift that `simless init` wrote.
let kitMarker = "// SimlessKit: headless render host for the `simless` CLI."

/// Whether `text` is a kit that `simless init` wrote: its first comment has
/// the kit's line.
func isSimlessKit(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.hasPrefix("//") || $0.isEmpty }.contains { $0 == kitMarker }
}
/// The App hook that `simless init` wrote into the `@main` App's init(),
/// under `#if SIMLESS` or the older `#if DEBUG && os(iOS)`, each line with
/// the indent of the first.
let hookPattern = #"(?m)^([ \t]*)#if (?:SIMLESS|DEBUG && os\(iOS\))\n\1SimlessHost\.startIfRequested\(\)\n\1#endif\n"#
/// The `@main` App declaration, up to its opening brace.
let appDeclPattern = #"@main\s+struct\s+\w+\s*:\s*([\w.]+\s*,\s*)*App\b[^{]*\{"#
/// The init() that `simless init` added to an App that had none, once the
/// hook is out of it: right after the declaration's brace, and empty.
let addedInit = "\n    init() {\n    }\n"

/// An app needs no simless source file: SimlessRuntime serves renders. Removes
/// what older `simless init` runs wrote: SimlessKit.swift, when its first
/// comment has the kit's line (`isSimlessKit`), and the App hook, when its text is exactly what init wrote.
/// Keeps the fixtures file. Returns a line for each thing removed, or left.
func removeKit(root: String, config: Config) throws -> [String] {
    var report: [String] = []
    let kit = "\(root)/\(config.kitFile)"
    if let text = try? String(contentsOfFile: kit, encoding: .utf8) {
        if isSimlessKit(text) {
            try FileManager.default.removeItem(atPath: kit)
            report.append("removed \(config.kitFile): SimlessRuntime serves renders")
        } else {
            report.append("left \(config.kitFile): simless did not write it")
        }
    }
    let skip = "\(root)/\(config.fixturesDir)/"
    for dir in config.sourceDirs {
        let base = dir == "." ? root : "\(root)/\(dir)"
        guard let e = FileManager.default.enumerator(atPath: base) else { continue }
        while let rel = e.nextObject() as? String {
            let path = "\(base)/\(rel)"
            guard rel.hasSuffix(".swift"), !path.hasPrefix(skip),
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  text.contains("SimlessHost.startIfRequested()") else { continue }
            let shown = dir == "." ? rel : "\(dir)/\(rel)"
            if let without = removeHook(from: text) {
                try without.write(toFile: path, atomically: true, encoding: .utf8)
                report.append("removed the App hook from \(shown)")
            } else {
                report.append("left SimlessHost.startIfRequested() in \(shown): it is not in the form simless init wrote; remove it by hand")
            }
        }
    }
    return report
}

/// `text` without the App hook (and the init() that held only the hook, when
/// simless added that init), or nil when the file has no `@main` App or no
/// hook in the exact form `simless init` wrote.
func removeHook(from text: String) -> String? {
    guard text.range(of: appDeclPattern, options: .regularExpression) != nil else { return nil }
    let hook = try! Regex(hookPattern)
    guard text.matches(of: hook).count == 1 else { return nil }
    var out = text.replacing(hook, with: "")
    if let decl = out.range(of: appDeclPattern, options: .regularExpression), out[decl.upperBound...].hasPrefix(addedInit) {
        out.removeSubrange(decl.upperBound..<out.index(decl.upperBound, offsetBy: addedInit.count))
    }
    return out
}
