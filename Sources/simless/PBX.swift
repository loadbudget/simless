// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Just enough of a project.pbxproj to know what a target compiles: the
/// synchronized folders (Xcode 16+) it lists, and the files of its Sources
/// build phase.
/// A synchronized folder or a file can sit inside classic groups, and its `path`
/// is then relative to its parent group, so paths are resolved through the group tree.
enum PBX {
    struct Object {
        let isa: String
        let path: String?
        let sourceTree: String?
        let children: [String]
        let body: String
    }

    private static let start = try! NSRegularExpression(pattern: #"^\t\t([0-9A-Za-z]+) /\*[^\n]*?\*/ = \{"#, options: .anchorsMatchLines)
    private static let ids = try! NSRegularExpression(pattern: #"([0-9A-Za-z]{16,}) /\*"#)

    private static func field(_ name: String, _ body: String) -> String? {
        guard let r = body.range(of: #"\b\#(name) = ("[^"]*"|[^;]+);"#, options: .regularExpression) else { return nil }
        let v = String(body[r]).dropFirst(name.count + 3).dropLast()
        return v.hasPrefix("\"") ? String(v.dropFirst().dropLast()) : String(v)
    }

    private static func list(_ name: String, _ body: String) -> [String] {
        guard let r = body.range(of: #"\b\#(name) = \(([^)]*)\)"#, options: .regularExpression) else { return [] }
        let s = String(body[r])
        return ids.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range(at: 1)) }
    }

    static func objects(_ pbx: String) -> [String: Object] {
        let ns = pbx as NSString
        var out: [String: Object] = [:]
        for m in start.matches(in: pbx, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let from = NSMaxRange(m.range)
            let lineEnd = ns.range(of: "\n", range: NSRange(location: from, length: ns.length - from)).location
            let rest = ns.substring(with: NSRange(location: from, length: (lineEnd == NSNotFound ? ns.length : lineEnd) - from))
            let body: String
            if rest.hasSuffix("};") {
                body = rest   // one line
            } else {
                let end = ns.range(of: "\n\t\t};", range: NSRange(location: from, length: ns.length - from)).location
                guard end != NSNotFound else { continue }
                body = ns.substring(with: NSRange(location: from, length: end - from))
            }
            out[id] = Object(isa: field("isa", body) ?? "", path: field("path", body), sourceTree: field("sourceTree", body),
                             children: list("children", body), body: body)
        }
        return out
    }

    /// The synchronized folders `target` compiles, relative to the project's directory.
    static func synchronizedFolders(target: String, pbx: String) -> [String] {
        let objects = objects(pbx)
        guard let t = nativeTarget(target, objects) else { return [] }
        return list("fileSystemSynchronizedGroups", t.body).compactMap(pathResolver(objects))
    }

    /// The files in `target`'s Sources build phase: the sources of a classic
    /// group, which Xcode lists one by one. A path is relative to the project's
    /// directory, or absolute for a file outside it (`<absolute>`).
    static func sourceFiles(target: String, pbx: String) -> [String] {
        sourceRefs(target: target, pbx: pbx).compactMap(\.path)
    }

    /// The Swift files of `target`'s Sources build phase that no path on disk
    /// can be given for, such as a generated file in `DERIVED_FILE_DIR`, with
    /// their `sourceTree`.
    static func unresolvedSwiftFiles(target: String, pbx: String) -> [(name: String, sourceTree: String)] {
        sourceRefs(target: target, pbx: pbx).filter { $0.path == nil && $0.name.hasSuffix(".swift") }.map { ($0.name, $0.sourceTree) }
    }

    /// Every native target, by name.
    static func targetNames(pbx: String) -> [String] {
        objects(pbx).values.filter { $0.isa == "PBXNativeTarget" }.compactMap { field("name", $0.body) }.sorted()
    }

    private static func sourceRefs(target: String, pbx: String) -> [(name: String, sourceTree: String, path: String?)] {
        let objects = objects(pbx)
        guard let t = nativeTarget(target, objects) else { return [] }
        let fullPath = pathResolver(objects)
        let phases = list("buildPhases", t.body).compactMap { objects[$0] }.filter { $0.isa == "PBXSourcesBuildPhase" }
        return phases.flatMap { list("files", $0.body) }.compactMap { buildFile in
            // A fileRef value reads `<id> /* <name> */`; a package product has a productRef instead.
            guard let ref = objects[buildFile].flatMap({ field("fileRef", $0.body) })?.split(separator: " ").first,
                  let file = objects[String(ref)] else { return nil }
            return (field("name", file.body) ?? file.path ?? String(ref), file.sourceTree ?? "", fullPath(String(ref)))
        }
    }

    private static func nativeTarget(_ name: String, _ objects: [String: Object]) -> Object? {
        objects.values.first { $0.isa == "PBXNativeTarget" && field("name", $0.body) == name }
    }

    /// An object's path relative to the project's directory, through the groups
    /// that hold it, or its absolute path. The project's `projectDirPath`, when
    /// set, is where `SOURCE_ROOT` and the main group start.
    private static func pathResolver(_ objects: [String: Object]) -> (String) -> String? {
        var parent: [String: String] = [:]
        for (id, o) in objects { for c in o.children { parent[c] = id } }
        let base = objects.values.first { $0.isa == "PBXProject" }.flatMap { field("projectDirPath", $0.body) } ?? ""
        func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : b.isEmpty ? a : "\(a)/\(b)" }
        func walk(_ id: String, depth: Int) -> String? {
            guard depth < 64, let o = objects[id] else { return nil }
            switch o.sourceTree {
            case "<absolute>": return o.path
            case "SOURCE_ROOT": return join(base, o.path ?? "")
            case "<group>":
                let up = parent[id].map { walk($0, depth: depth + 1) } ?? base
                guard let up else { return nil }
                if let p = o.path, p.hasPrefix("/") { return p }
                return join(up, o.path ?? "")
            default: return nil
            }
        }
        return { walk($0, depth: 0) }
    }
}
