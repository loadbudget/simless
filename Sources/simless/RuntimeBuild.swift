// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// SimlessRuntime.dylib, injected into every host (see Runtime/Runtime.swift).
/// Built from the simless source folder for this Xcode, signed with the team's
/// identity, and cached until simless, Xcode or the Swift compiler changes.
enum RuntimeBuild {
    /// The iOS version the runtime and its module are built for.
    static let iosTarget = "17.0"

    static func dylib(team: String) throws -> String {
        let unsigned = try compiled()
        let dir = (unsigned as NSString).deletingLastPathComponent
        let out = "\(dir)/signed-\(shortHash(team))/SimlessRuntime.dylib"
        if exists(out) { return out }
        return try withLock("runtime-build") {
            if exists(out) { return out }
            try mkdirp((out as NSString).deletingLastPathComponent)
            try? FileManager.default.removeItem(atPath: out + ".tmp")
            try FileManager.default.copyItem(atPath: unsigned, toPath: out + ".tmp")
            try Signing.sign(out + ".tmp", identity: try Signing.identity(team: team).0)
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
            return out
        }
    }

    /// The runtime for native slots: retagged for Mac Catalyst and signed ad hoc.
    static func nativeDylib() throws -> String {
        let unsigned = try compiled()
        let dir = (unsigned as NSString).deletingLastPathComponent
        let out = "\(dir)/native/SimlessRuntime.dylib"
        if exists(out) { return out }
        return try withLock("runtime-build") {
            if exists(out) { return out }
            try mkdirp((out as NSString).deletingLastPathComponent)
            try? FileManager.default.removeItem(atPath: out + ".tmp")
            try FileManager.default.copyItem(atPath: unsigned, toPath: out + ".tmp")
            try MachO.retagForCatalyst(out + ".tmp")
            try Native.signAdHoc([out + ".tmp"])
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
            return out
        }
    }

    /// Compiles the runtime ahead of time (`simless up` does it next to the
    /// app's build, since it needs nothing from it).
    static func prebuild() { _ = try? compiled() }

    /// Where this build's `SimlessRuntime.swiftmodule` is. Slots get a copy
    /// (`RuntimeHost.installModule`), and dylibs compile against that copy.
    static func moduleDir() throws -> String { (try compiled() as NSString).deletingLastPathComponent }

    /// The cache key of a runtime build. The Swift compiler's version is part of
    /// it: a binary .swiftmodule loads only in the compiler that wrote it.
    static func stamp(version: String, xcode: String, swiftc: String, sources: [(path: String, mtime: String)]) -> String {
        shortHash(([version, xcode, swiftc] + sources.map { "\($0.path) \($0.mtime)" }).joined(separator: "|"))
    }

    /// A build folder holds a usable runtime only with both the library and
    /// the module that dylibs import.
    static func isBuilt(_ dir: String) -> Bool {
        exists("\(dir)/SimlessRuntime.dylib") && exists("\(dir)/SimlessRuntime.swiftmodule")
    }

    /// The runtime compiled for this simless, Xcode and Swift compiler, not yet signed.
    static func compiled() throws -> String {
        let sources = ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.toolRoot)/Runtime")) ?? [])
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".c") || $0.hasSuffix(".m") }.sorted().map { "\(Paths.toolRoot)/Runtime/\($0)" }
        let xcode = (try? Shell.run(["xcodebuild", "-version"]).out) ?? ""
        let swiftc = (try? Shell.run(["xcrun", "swiftc", "--version"]).out) ?? ""
        let stamp = stamp(version: version, xcode: xcode, swiftc: swiftc, sources: sources.map { ($0, "\(mtime($0))") })
        let dir = "\(Paths.cache)/runtime/\(stamp)"
        let out = "\(dir)/SimlessRuntime.dylib"
        try ensureBuilt(dir) {
            let t = now()
            let sdk = try Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            var objects: [String] = []
            for c in sources where c.hasSuffix(".c") || c.hasSuffix(".m") {
                let o = "\(dir)/\(((c as NSString).lastPathComponent as NSString).deletingPathExtension).o"
                try Shell.check(["xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-target", "arm64-apple-ios\(iosTarget)", "-isysroot", sdk, c, "-o", o],
                                what: "compile \((c as NSString).lastPathComponent)")
                objects.append(o)
            }
            // The module lets the fixtures, previews and patch dylibs of an app
            // without SimlessKit `import SimlessRuntime` for its SimlessRegistry.
            // They bind to the injected runtime at load time.
            try Shell.check(["xcrun", "swiftc", "-emit-library", "-O", "-module-name", "SimlessRuntime",
                             "-emit-module", "-emit-module-path", "\(dir)/SimlessRuntime.swiftmodule",
                             "-target", "arm64-apple-ios\(iosTarget)", "-sdk", sdk, "-swift-version", "5",
                             "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup", "-framework", "IOKit", "-framework", "Security",
                             "-o", out + ".tmp"]
                            + sources.filter { $0.hasSuffix(".swift") } + objects, what: "build SimlessRuntime")
            // The library last: with it, the folder counts as built.
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
            Log.step("built SimlessRuntime in \(secs(t))")
            // Older builds of the runtime are no use once this one exists.
            for old in (try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.cache)/runtime")) ?? [] where old != stamp {
                try? FileManager.default.removeItem(atPath: "\(Paths.cache)/runtime/\(old)")
            }
        }
        return out
    }

    /// Runs `build` in `dir` unless the folder holds a usable runtime. A
    /// part-built folder (a library with no module) starts over empty, without
    /// the signed copies made from it.
    static func ensureBuilt(_ dir: String, build: () throws -> Void) throws {
        if isBuilt(dir) { return }
        try withLock("runtime-build") {
            if isBuilt(dir) { return }
            try? FileManager.default.removeItem(atPath: dir)
            try mkdirp(dir)
            try build()
        }
    }

    /// Xcode's test frameworks for an iOS app on the Mac (what xcodebuild puts
    /// on DYLD_FRAMEWORK_PATH for "Designed for iPad" test runs).
    static var developerDir: String {
        Shell.developerDir ?? (try? Shell.run(["/usr/bin/xcode-select", "-p"], useXcode: false).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "/Applications/Xcode.app/Contents/Developer"
    }

    static var testFrameworkEnv: [String: String] {
        let p = "\(developerDir)/Platforms/MacOSX.platform/Developer"
        return ["DYLD_FRAMEWORK_PATH": "\(p)/Library/Frameworks:\(p)/Library/PrivateFrameworks",
                "DYLD_LIBRARY_PATH": "\(p)/usr/lib"]
    }
}
