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
/// the old file was kept, a line for each file changed or left, and a line for
/// each use of SimlessHost that stopped the removal.
func initFiles(root: String, force: Bool, fresh: Config) throws
    -> (config: Config, kept: Bool, removed: [String], blocked: [String]) {
    let path = "\(root)/\(Workspace.configName)"
    // A file that doesn't load stops init, unless `force` replaces it.
    let previous = !exists(path) ? nil : force ? (try? Workspace.load(at: root))?.config : try Workspace.load(at: root).config
    let kept = previous != nil && !force
    var config = fresh
    if config.kitDir == nil { config.kitDir = previous?.kitDir }
    if kept, let previous { config = previous } else { try writeConfig(config, to: path) }
    let (removed, blocked) = try removeKit(root: root, config: previous ?? config)
    return (config, kept, removed, blocked)
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

/// A line of the app's sources that names SimlessHost, which only the kit defines.
typealias SimlessUse = (file: String, line: Int, text: Substring)

/// Each line that names SimlessHost in the .swift files of `config.sourceDirs`,
/// outside the kit file. It skips hidden folders and the folder of another app:
/// one with its own `.simless.json`, or with an Xcode project other than
/// `config.project`.
func simlessUses(root: String, config: Config) -> [SimlessUse] {
    let kit = "\(root)/\(config.kitFile)"
    let ownProject = "\(root)/\(config.project)"
    var uses: [SimlessUse] = []
    for dir in config.sourceDirs {
        let base = dir == "." ? root : "\(root)/\(dir)"
        guard let e = FileManager.default.enumerator(atPath: base) else { continue }
        while let rel = e.nextObject() as? String {
            let path = "\(base)/\(rel)"
            let name = (rel as NSString).lastPathComponent
            if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                let otherApp = entries.contains(Workspace.configName)
                    || entries.contains { $0.hasSuffix(".xcodeproj") && "\(path)/\($0)" != ownProject }
                if name.hasPrefix(".") || otherApp { e.skipDescendants() }
                continue
            }
            guard rel.hasSuffix(".swift"), path != kit,
                  let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains("SimlessHost") else { continue }
            let shown = dir == "." ? rel : "\(dir)/\(rel)"
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains("SimlessHost") {
                uses.append((shown, i + 1, line))
            }
        }
    }
    return uses
}

/// What the user does with a use of SimlessHost that init does not remove.
func fixFor(_ use: SimlessUse) -> String {
    use.text.contains("SimlessHost.startIfRequested()") ? "remove this call and the #if block around it"
        : use.text.contains("SimlessHost.isActive") ? "use ProcessInfo.processInfo.arguments.contains(\"--simless-port\") instead"
        : "remove it: SimlessHost is only in SimlessKit.swift"
}

/// An app needs no simless source file: SimlessRuntime serves renders. Removes
/// what older `simless init` runs wrote, all of it or nothing: SimlessKit.swift,
/// when its first comment has the kit's line (`isSimlessKit`), and the App
/// hook, when its text is exactly what init wrote. When another use of
/// SimlessHost would stay, it changes nothing and returns each use in
/// `blocked`. Keeps the fixtures file.
func removeKit(root: String, config: Config) throws -> (removed: [String], blocked: [String]) {
    let kit = "\(root)/\(config.kitFile)"
    let kitText = try? String(contentsOfFile: kit, encoding: .utf8)
    let uses = simlessUses(root: root, config: config)
    if let kitText, !isSimlessKit(kitText), uses.isEmpty {
        return (["left \(config.kitFile): simless did not write it"], [])
    }
    guard kitText != nil || !uses.isEmpty else { return ([], []) }

    // Each file whose only use is a hook that `removeHook` takes out.
    var edits: [(file: String, text: String)] = []
    var blocked: [String] = []
    if let kitText, !isSimlessKit(kitText) {
        blocked.append("\(config.kitFile): simless did not write it; delete it by hand if it is an older SimlessKit")
    }
    if kitText == nil { blocked.append("\(config.kitFile): not there, so SimlessHost comes from another file") }
    for file in Set(uses.map(\.file)).sorted() {
        let inFile = uses.filter { $0.file == file }
        let path = "\(root)/\(file)"
        if inFile.count == 1, let text = try? String(contentsOfFile: path, encoding: .utf8), let without = removeHook(from: text) {
            edits.append((file, without))
        } else {
            blocked += inFile.map { "\($0.file):\($0.line): \(fixFor($0))" }
        }
    }
    if !blocked.isEmpty { return ([], blocked) }

    try FileManager.default.removeItem(atPath: kit)
    var removed = ["removed \(config.kitFile): SimlessRuntime serves renders"]
    for edit in edits {
        try edit.text.write(toFile: "\(root)/\(edit.file)", atomically: true, encoding: .utf8)
        removed.append("removed the App hook from \(edit.file)")
    }
    removed.append("note: `simless calibrate` needs the kit and the App hook for now, so it does not run on this app")
    return (removed, [])
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
