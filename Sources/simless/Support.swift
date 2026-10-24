// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Outside main.swift, so tests read it too: a global there is set only when `main` runs.
let version = "0.7.2"

struct SimlessError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// MARK: - Output

enum Log {
    static var verbose = false
    static func info(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func step(_ s: String) { info("▸ " + s) }
    static func debug(_ s: String) { if verbose { info("  " + s) } }
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func secs(_ since: Double) -> String { String(format: "%.1fs", now() - since) }

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Everything simless builds or caches. The agent only accepts patches from here.
    static let cache = "\(home)/Library/Caches/simless"
    static let support = "\(home)/Library/Application Support/Simless"
    static let locks = "\(cache)/locks"
    /// Where every worktree's slots and their records were before each worktree
    /// kept its own. Read only to remove them once (`Cleanup.migrateLegacyState`).
    static let legacySlots = "\(cache)/slots"
    static let legacyStatePath = "\(cache)/state.json"
    static let agentApp = "\(support)/SimlessAgent.app"
    static let agentSocket = "\(support)/agent.sock"

    /// The simless checkout (templates, runtime and agent sources): $SIMLESS_ROOT,
    /// else the checkout the running binary sits in (so a checkout moved or
    /// restored from a CI cache still works), else where it was compiled.
    static let toolRoot: String = {
        func isRoot(_ dir: String) -> Bool { exists("\(dir)/Templates/SimlessKit.swift") && exists("\(dir)/Runtime") }
        if let env = ProcessInfo.processInfo.environment["SIMLESS_ROOT"], isRoot(env) { return env }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<6 {
                if isRoot(dir.path) { return dir.path }
                dir.deleteLastPathComponent()
            }
        }
        var url = URL(fileURLWithPath: #filePath)   // <root>/Sources/simless/Support.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }()

    /// A worktree's own folder: its builds, its slot records and its slots.
    /// `cache` is the simless cache folder; tests pass a temporary one.
    static func workDir(forWorktree worktree: String, cache: String = Paths.cache) -> String {
        "\(cache)/work/\(shortHash(worktree))-\((worktree as NSString).lastPathComponent)"
    }

    /// The records of a worktree's slots.
    static func statePath(forWorktree worktree: String, cache: String = Paths.cache) -> String {
        "\(workDir(forWorktree: worktree, cache: cache))/state.json"
    }

    /// The folders of a worktree's slots, one per slot.
    static func slotsDir(forWorktree worktree: String) -> String {
        "\(workDir(forWorktree: worktree))/slots"
    }
}

/// FNV-1a: enough to key cache directories and slots, not a checksum.
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

func shortHash(_ s: String) -> String {
    String(fnv1a(s), radix: 16).prefix(10).description
}

/// The slot number of a worktree: a hash of its path, in decimal. Each
/// worktree gets its own number with no shared counter, and the number stays
/// digits, which is what SimlessAgent's `.simless[0-9]+` check accepts.
func slotNumber(forWorktree worktree: String) -> Int {
    Int(fnv1a(worktree) % 10_000_000_000)
}

func mkdirp(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

/// An APFS clone of `src` at `dst`, writable by its owner. Build products from
/// a read-only SwiftPM checkout (a binary xcframework) keep its mode, and
/// retagging and signing write into the clone. The original is never written.
func cloneWritable(_ src: String, to dst: String, what: String) throws {
    try Shell.check(["/bin/cp", "-c", "-R", src, dst], what: what)
    try Shell.check(["/bin/chmod", "-R", "u+w", dst], what: "make the \((dst as NSString).lastPathComponent) clone writable")
}

func mtime(_ path: String) -> Double {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
        .timeIntervalSinceReferenceDate ?? 0
}

// MARK: - Processes

struct Shell {
    /// DEVELOPER_DIR pointing at full Xcode when xcode-select points at CommandLineTools.
    static let developerDir: String? = {
        if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return d }
        let selected = (try? run(["/usr/bin/xcode-select", "-p"], useXcode: false).out)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selected.contains("CommandLineTools"), exists("/Applications/Xcode.app") {
            return "/Applications/Xcode.app/Contents/Developer"
        }
        return nil
    }()

    struct Result { let code: Int32; let out: String }

    /// Runs a command, capturing stdout+stderr (into `logPath` too, if given).
    @discardableResult
    /// `stdoutOnly`: discard stderr (for commands whose stdout is JSON).
    static func run(_ args: [String], cwd: String? = nil, env: [String: String] = [:],
                    logPath: String? = nil, useXcode: Bool = true, stdoutOnly: Bool = false) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/usr/bin/env")
        p.arguments = args[0].hasPrefix("/") ? Array(args.dropFirst()) : args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        if useXcode, let dev = developerDir { environment["DEVELOPER_DIR"] = dev }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        // Through a file, not a pipe: xcodebuild output can exceed pipe buffers.
        let out = logPath ?? NSTemporaryDirectory() + "simless-\(UUID().uuidString).log"
        try mkdirp((out as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        p.standardOutput = handle
        p.standardError = stdoutOnly ? FileHandle.nullDevice : handle
        try p.run()
        p.waitUntilExit()
        try handle.close()
        let text = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        if logPath == nil { try? FileManager.default.removeItem(atPath: out) }
        Log.debug("$ \(args.joined(separator: " ")) -> \(p.terminationStatus)")
        return Result(code: p.terminationStatus, out: text)
    }

    /// Like `run` with a log file, but hands each output line to `onLine` as it
    /// arrives. `tick` runs about four times a second; returning false
    /// terminates the command (its result then has exit code 15).
    static func stream(_ args: [String], cwd: String? = nil, logPath: String, env: [String: String]? = nil,
                       onLine: (String) -> Void, tick: () -> Bool) throws -> Result {
        let p = Process()
        // A path runs directly, as in `run`: /usr/bin/env is protected, so
        // macOS drops DYLD_* variables when it starts.
        p.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/usr/bin/env")
        p.arguments = args[0].hasPrefix("/") ? Array(args.dropFirst()) : args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = env ?? ProcessInfo.processInfo.environment
        if let dev = developerDir { environment["DEVELOPER_DIR"] = dev }
        p.environment = environment
        try mkdirp((logPath as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        p.standardOutput = handle
        p.standardError = handle
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: logPath))
        var pending = Data()
        func drain() {
            pending.append(reader.availableData)
            while let nl = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        try p.run()
        var stopped = false
        while p.isRunning {
            drain()
            if !stopped, !tick() {
                stopped = true
                p.terminate()
                let deadline = now() + 5
                while p.isRunning && now() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        p.waitUntilExit()
        try handle.close()
        drain()
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        Log.debug("$ \(args.joined(separator: " ")) -> \(p.terminationStatus)")
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        return Result(code: stopped ? 15 : p.terminationStatus, out: text)
    }

    @discardableResult
    static func check(_ args: [String], cwd: String? = nil, logPath: String? = nil,
                      what: String? = nil, stdoutOnly: Bool = false) throws -> String {
        let r = try run(args, cwd: cwd, logPath: logPath, stdoutOnly: stdoutOnly)
        guard r.code == 0 else {
            let tail = r.out.split(separator: "\n").suffix(15).joined(separator: "\n")
            throw SimlessError("\(what ?? args.first ?? "command") failed (exit \(r.code))"
                          + (logPath.map { "; log: \($0)" } ?? "") + "\n" + tail)
        }
        return r.out
    }
}

// MARK: - Sandbox extensions

/// The slot app runs in the Mac's app sandbox, which can't read the repository.
/// simless isn't sandboxed, so it can issue a sandbox extension: a token that
/// grants read-only access to one directory tree, which SimlessKit consumes at
/// launch. (The slot's profile can't carry a temporary-exception entitlement;
/// installd rejects the app.)
enum Sandbox {
    static func readToken(_ path: String) -> String? {
        guard let h = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW),
              let sym = dlsym(h, "sandbox_extension_issue_file") else { return nil }
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let t = unsafeBitCast(sym, to: Issue.self)("com.apple.app-sandbox.read", resolved, 0) else { return nil }
        defer { free(t) }
        return String(cString: t)
    }
}

// MARK: - Default DerivedData

/// Runs an xcodebuild call that can't take -derivedDataPath and removes any
/// folder it newly created in ~/Library/Developer/Xcode/DerivedData for these
/// projects. Folders that existed before (e.g. Xcode's own) are left alone.
func withDefaultDerivedDataGuard<T>(projectNames: [String], _ body: () throws -> T) rethrows -> T {
    let dd = "\(Paths.home)/Library/Developer/Xcode/DerivedData"
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dd)) ?? [])
    defer {
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: dd)) ?? [] where !before.contains(dir) {
            if projectNames.contains(where: { dir.hasPrefix("\($0)-") }) {
                try? FileManager.default.removeItem(atPath: "\(dd)/\(dir)")
            }
        }
    }
    return try body()
}

// MARK: - Locks

/// flock-based mutual exclusion across every simless process (all agents, all projects).
func withLock<T>(_ name: String, _ body: () throws -> T) throws -> T {
    try mkdirp(Paths.locks)
    let fd = open("\(Paths.locks)/\(name).lock", O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw SimlessError("cannot open lock \(name)") }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        Log.debug("waiting for lock \(name)")
        flock(fd, LOCK_EX)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
}

/// Takes one of `count` build tokens so concurrent agents don't all compile at once.
func withBuildToken<T>(count: Int, _ body: () throws -> T) throws -> T {
    try withToken("build", count: count, body)
}

/// Takes one of `count` tokens named `name`, so at most `count` of those run at once.
func withToken<T>(_ name: String, count: Int, _ body: () throws -> T) throws -> T {
    try mkdirp(Paths.locks)
    while true {
        for i in 0..<count {
            let fd = open("\(Paths.locks)/\(name)-\(i).lock", O_CREAT | O_RDWR, 0o644)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(fd, LOCK_UN); close(fd) }
                return try body()
            }
            if fd >= 0 { close(fd) }
        }
        Log.debug("all \(count) \(name) tokens busy; waiting")
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// MARK: - Slot records, one file per worktree, guarded by its "state-<hash>" lock

struct SlotRecord: Codable {
    var bundleBase: String      // e.g. com.example.app
    var n: Int                  // slotNumber(forWorktree:) -> <bundleBase>.simless<n>
    var worktree: String
    var port: Int
    var builtAt: Double = 0     // reference-date seconds of the last full build
    var build: String?          // the id of the sources that build was made from (Workspace.sourcesID)
    var sources: String?        // the id of the sources the host's code reflects: the build's, or the newest patch's
    var patch: Int = 0          // patches applied since that build
    var lastPatch: String?      // newest patch dylib; re-applied whenever the host relaunches
    var covered: [String]?      // fixtures the newest patch renders with the edits
    var stale: [String]?        // fixtures that reach an edit the newest patch doesn't cover
    var kind: String?           // nil: the render host. "test": unit tests. "ui1"...: UI test app hosts
    var builtWithKit: Bool?     // whether the last full build had SimlessKit; nil: a record from before it was kept
    /// Whether the installed build serves renders with SimlessKit. A record
    /// with no answer is from a simless that needed the kit in every app.
    var kitInBuild: Bool { builtWithKit ?? true }
    var slotID: String { "\(bundleBase).simless\(n)\(kind.map { "-" + $0 } ?? "")" }
    var dir: String { "\(Paths.slotsDir(forWorktree: worktree))/\(slotID)" }
}

/// The slots of one worktree, kept in `Paths.statePath(forWorktree:)`. The
/// name is from when one file held every worktree's slots.
struct GlobalState: Codable {
    var slots: [SlotRecord] = []

    /// The lock that guards a worktree's records. `hash` is `shortHash` of the
    /// worktree path, which is also the start of its work folder's name.
    static func lockName(forWorktree worktree: String) -> String { lockName(hash: shortHash(worktree)) }
    static func lockName(hash: String) -> String { "state-\(hash)" }

    /// The records in `path`; none when the file is missing or unreadable.
    static func load(path: String) -> GlobalState {
        guard let d = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(GlobalState.self, from: d) else { return GlobalState() }
        return s
    }

    static func load(worktree: String, cache: String = Paths.cache) -> GlobalState {
        load(path: Paths.statePath(forWorktree: worktree, cache: cache))
    }

    func save(worktree: String, cache: String = Paths.cache) throws {
        try mkdirp(Paths.workDir(forWorktree: worktree, cache: cache))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: Paths.statePath(forWorktree: worktree, cache: cache)), options: .atomic)
    }

    /// Every worktree's slots, read without a lock, for reports and cleanup.
    static func all(cache: String = Paths.cache) -> [SlotRecord] {
        let work = "\(cache)/work"
        return ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [])
            .flatMap { load(path: "\(work)/\($0)/state.json").slots }
    }

    /// Returns this worktree's slot, with the number of its path and a free port.
    /// A `kind` slot shares its render slot's number (app.simless<n>, app.simless<n>-test).
    static func slot(bundleBase: String, worktree: String, kind: String? = nil) throws -> SlotRecord {
        try withLock(lockName(forWorktree: worktree)) {
            var s = load(worktree: worktree)
            let others = all().filter { $0.worktree != worktree }
            let (r, replaced) = try s.assign(bundleBase: bundleBase, worktree: worktree, kind: kind,
                                             others: others, keep: keepsPort) { usedPorts in
                try freePort(avoiding: usedPorts)
            }
            for old in replaced {
                Log.step("moving \(old.slotID) to \(r.slotID): slots are now numbered by worktree path")
                Cleanup.removeSlot(old)
            }
            try s.save(worktree: worktree)
            return r
        }
    }

    /// Whether a slot keeps its port: a stopped host's port may since have
    /// gone to another program.
    static func keepsPort(_ r: SlotRecord) -> Bool { portIsFree(r.port) || RuntimeHost.hasProcess(r) }

    /// `record` as saved, with a new port if another program took its port
    /// while its host was stopped.
    static func withFreePort(_ record: SlotRecord) throws -> SlotRecord {
        try withLock(lockName(forWorktree: record.worktree)) {
            var s = load(worktree: record.worktree)
            guard let i = s.slots.firstIndex(where: { $0.slotID == record.slotID }) else { return record }
            if !keepsPort(s.slots[i]) {
                let others = all().filter { $0.worktree != record.worktree }
                s.slots[i].port = try freePort(avoiding: Set((s.slots + others).map(\.port)))
                try s.save(worktree: record.worktree)
            }
            return s.slots[i]
        }
    }

    /// The slot of `worktree`, added if it has none. A slot of that worktree
    /// under an older number comes back in `replaced`, for the caller to remove.
    /// Two worktrees whose paths hash to one number throw, because they would
    /// share an app container: `others` are the other worktrees' slots, which
    /// live in their own files. A slot whose port `keep` refuses gets a new one.
    mutating func assign(bundleBase: String, worktree: String, kind: String?,
                         others: [SlotRecord] = [],
                         keep: (SlotRecord) -> Bool = { _ in true },
                         port: (Set<Int>) throws -> Int) throws -> (SlotRecord, replaced: [SlotRecord]) {
        let n = slotNumber(forWorktree: worktree)
        let same = { (r: SlotRecord) in r.bundleBase == bundleBase && r.kind == kind }
        if let i = slots.firstIndex(where: { same($0) && $0.worktree == worktree && $0.n == n }) {
            if !keep(slots[i]) {
                slots[i].port = try port(Set((slots + others).map(\.port)))
            }
            return (slots[i], [])
        }
        if let other = slots.first(where: { same($0) && $0.n == n }) ?? others.first(where: { same($0) && $0.n == n }) {
            throw SimlessError("\(other.worktree) and \(worktree) both hash to slot \(other.slotID); move one of them")
        }
        let replaced = slots.filter { same($0) && $0.worktree == worktree }
        slots.removeAll { same($0) && $0.worktree == worktree }
        var r = SlotRecord(bundleBase: bundleBase, n: n, worktree: worktree, port: try port(Set((slots + others).map(\.port))))
        r.kind = kind
        slots.append(r)
        return (r, replaced)
    }

    static func update(_ record: SlotRecord) throws {
        try withLock(lockName(forWorktree: record.worktree)) {
            var s = load(worktree: record.worktree)
            s.slots.removeAll { $0.slotID == record.slotID }
            s.slots.append(record)
            try s.save(worktree: record.worktree)
        }
    }

    static func release(_ record: SlotRecord) throws {
        try withLock(lockName(forWorktree: record.worktree)) {
            var s = load(worktree: record.worktree)
            s.slots.removeAll { $0.slotID == record.slotID }
            try s.save(worktree: record.worktree)
        }
    }
}

/// A port on 127.0.0.1 that the OS reports free, and not in `avoiding` (the
/// ports of stopped hosts, which listen again when they start). The OS picks it
/// with a bind to port 0. Another program can take it before the host binds
/// it. The host then doesn't start, and the next command finds the port busy
/// with no host of the slot on it, and picks again. `pick` stands in for the
/// OS in tests.
func freePort(avoiding: Set<Int> = [], pick: () throws -> Int = osFreePort) throws -> Int {
    for _ in 0..<20 {
        let port = try pick()
        if !avoiding.contains(port) { return port }
    }
    throw SimlessError("the OS kept giving ports that stopped simless hosts hold")
}

/// The port the OS gives a bind to 127.0.0.1:0.
func osFreePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SimlessError("cannot open a socket to find a free port") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
    }
    guard bound else { throw SimlessError("the OS gave no free port on 127.0.0.1") }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Whether nothing listens on 127.0.0.1:`port`.
func portIsFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// A value shared between threads, behind a lock.
final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
