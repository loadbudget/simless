// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// simless cleans up after itself:
/// - every command first collects garbage left by worktrees that no longer exist
///   (agents delete their worktrees when done), or that haven't used simless
///   for two weeks: host, slot, the app's data container, build cache;
/// - crash reports of its hosts go after a day, and a test run starts with an
///   empty tmp in the app's container;
/// - hosts exit on their own after 30 idle minutes;
/// - only the newest few patches are kept; the shared compile cache is capped.
enum Cleanup {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let keepPatches = 3
    static let compileCacheLimitGB = 8.0

    /// Stops the host, unregisters the install, deletes the slot directory:
    /// `dir`, for a slot whose folder isn't `slot.dir` (an old layout's).
    static func removeSlot(_ slot: SlotRecord, dir: String? = nil) {
        Slots.stop(slot)
        Slots.terminateAll(slot)   // test and UI-test hosts don't answer the render protocol
        if let dir { Native.terminate(under: "\(dir)/Native") }
        removeSlotDir(dir ?? slot.dir)
    }

    private static func removeSlotDir(_ dir: String) {
        let installed = "\(dir)/Debug-iphoneos/.XCInstall"
        for app in (try? FileManager.default.contentsOfDirectory(atPath: installed)) ?? [] where app.hasSuffix(".app") {
            wipeContainer(app: "\(installed)/\(app)", runtime: "\(dir)/SimlessRuntime.dylib")
            _ = try? Shell.run([lsregister, "-u", "\(installed)/\(app)"], useXcode: false)
        }
        // A native slot's data is its home folder (deleted with the slot) and its
        // preferences domains, which cfprefsd keeps in ~/Library/Preferences.
        if exists("\(dir)/Native") {
            let id = (dir as NSString).lastPathComponent
            Native.wipePreferences(slotID: id, deleteFiles: true)
            for app in (try? FileManager.default.contentsOfDirectory(atPath: "\(dir)/Native")) ?? [] where app.hasSuffix(".app") {
                _ = try? Shell.run([lsregister, "-u", "\(dir)/Native/\(app)"], useXcode: false)
            }
        }
        removeCrashReports(slotID: (dir as NSString).lastPathComponent, olderThan: 0)
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Empties the slot app's data container. macOS protects app containers
    /// from other processes, so the app does it itself: launched with
    /// SIMLESS_WIPE=1, SimlessRuntime deletes its files and quits.
    /// Returns false when the app wouldn't launch at all.
    @discardableResult
    static func wipeContainer(app: String, runtime: String) -> Bool {
        guard exists(runtime) else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-W", "-g", "-j", "-n", "--env", "DYLD_INSERT_LIBRARIES=\(runtime)", "--env", "SIMLESS_WIPE=1", app]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = now() + 20
        while p.isRunning && now() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return true }
        return p.terminationStatus == 0
    }

    /// Crash reports macOS wrote for simless hosts (a slot's, or every slot's),
    /// older than `age` seconds.
    static func removeCrashReports(slotID: String? = nil, olderThan age: TimeInterval) {
        let dir = "\(Paths.home)/Library/Logs/DiagnosticReports"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".ips") {
            let path = "\(dir)/\(file)"
            guard Date().timeIntervalSinceReferenceDate - mtime(path) > age,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 600), as: UTF8.self)
            try? handle.close()
            guard let r = head.range(of: #""bundleID":"([^"]+)""#, options: .regularExpression) else { continue }
            let id = head[r].dropFirst("\"bundleID\":\"".count).dropLast()
            let ours = slotID.map { id == $0 } ?? (id.range(of: #"\.simless\d+(-[a-z0-9]+)?$"#, options: .regularExpression) != nil)
            if ours { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// How long a worktree's .simless.json must stay missing before its slots
    /// and builds go. A build machine that re-extracts a project's sources on
    /// every sync (rm -rf, then untar) would otherwise lose them to another
    /// project's command running inside that window.
    static var missingGrace: TimeInterval { env("SIMLESS_GONE_MINUTES").map { $0 * 60 } ?? 600 }

    /// Days without a simless command after which a worktree's hosts, slots and builds go.
    static var unusedDays: Double { env("SIMLESS_UNUSED_DAYS") ?? 14 }

    private static func env(_ name: String) -> Double? { ProcessInfo.processInfo.environment[name].flatMap(Double.init) }

    /// Whether `worktree` has been gone (no .simless.json) for longer than the grace period.
    /// The first time it's seen missing is recorded in its build folder.
    static func goneForGood(_ worktree: String) -> Bool {
        let marker = "\(Paths.workDir(forWorktree: worktree))/missing-since"
        if exists("\(worktree)/\(Workspace.configName)") {
            try? FileManager.default.removeItem(atPath: marker)
            return false
        }
        if !exists(marker) {
            try? mkdirp((marker as NSString).deletingLastPathComponent)
            FileManager.default.createFile(atPath: marker, contents: nil)
            return false
        }
        return Date().timeIntervalSinceReferenceDate - mtime(marker) > missingGrace
    }

    /// Cheap enough to run on every invocation.
    static func collectGarbage() {
        migrateLegacyState()
        let work = "\(Paths.cache)/work"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [] {
            collectGarbage(workDir: "\(work)/\(name)", lock: GlobalState.lockName(hash: String(name.prefix { $0 != "-" })))
        }
        // Crash reports of simless hosts, after a day.
        removeCrashReports(olderThan: 86_400)
        Native.removeOrphanPreferences(known: Set(GlobalState.all().map(\.slotID)))
    }

    /// One worktree's folder: all of it when its worktree is gone or hasn't
    /// used simless for `unusedDays` (its slots first, so their hosts stop and
    /// their installs are unregistered), else its slot folders no record names.
    private static func collectGarbage(workDir dir: String, lock: String) {
        _ = try? withLock(lock) {
            let slots = GlobalState.load(path: "\(dir)/state.json").slots
            let owner = (try? String(contentsOfFile: "\(dir)/worktree.txt", encoding: .utf8)) ?? slots.first?.worktree
            // Unmarked and recent: possibly being created right now.
            let recent = Date().timeIntervalSinceReferenceDate - mtime(dir) < 1800
            if let owner, goneForGood(owner) {
                for slot in slots {
                    Log.step("cleaning up \(slot.slotID): worktree \(slot.worktree) no longer exists")
                    removeSlot(slot)
                }
            } else if owner == nil && !recent {
                for slot in slots { removeSlot(slot) }
            } else if !slots.isEmpty, lastUsed(dir) > 0, Date().timeIntervalSinceReferenceDate - lastUsed(dir) > unusedDays * 86_400 {
                // The worktree exists but hasn't used simless for a while: its
                // hosts, slots and builds go (`simless up` makes them again).
                for slot in slots {
                    Log.step("cleaning up \(slot.slotID): \(slot.worktree) hasn't used simless for \(Int(unusedDays)) days")
                    removeSlot(slot)
                }
            } else {
                // Slot dirs no record points at (e.g. after a crash mid-`simless up`).
                let known = Set(slots.map(\.slotID))
                for slotDir in (try? FileManager.default.contentsOfDirectory(atPath: "\(dir)/slots")) ?? [] where !known.contains(slotDir) {
                    removeSlotDir("\(dir)/slots/\(slotDir)")
                }
                return
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// The slot folders of the old shared layout to remove, each with the
    /// record that names it (nil for a folder no record names).
    static func legacySlotDirs(_ state: GlobalState, folders: [String], legacySlots: String = Paths.legacySlots)
        -> [(slot: SlotRecord?, dir: String)] {
        let named = Set(state.slots.map(\.slotID))
        return state.slots.map { (slot: $0, dir: "\(legacySlots)/\($0.slotID)") }
            + folders.filter { !named.contains($0) }.map { (slot: nil, dir: "\(legacySlots)/\($0)") }
    }

    /// Removes the slots of the old layout, where one `state.json` and one
    /// `slots/` folder held every worktree's. Under the old "state" lock, so an
    /// older simless doesn't write them during the removal. An older simless
    /// that runs later writes them again, and the next command here removes
    /// its slots again, so every simless on a Mac updates together.
    static func migrateLegacyState() {
        guard exists(Paths.legacyStatePath) || exists(Paths.legacySlots) else { return }
        _ = try? withLock("state") {
            guard exists(Paths.legacyStatePath) || exists(Paths.legacySlots) else { return }
            let state = GlobalState.load(path: Paths.legacyStatePath)
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: Paths.legacySlots)) ?? []
            for (slot, dir) in legacySlotDirs(state, folders: folders) {
                if let slot { removeSlot(slot, dir: dir) } else { removeSlotDir(dir) }
            }
            try? FileManager.default.removeItem(atPath: Paths.legacyStatePath)
            try? FileManager.default.removeItem(atPath: Paths.legacySlots)
            Log.step("removed the slots of the old shared state.json; `simless up` in a worktree makes its slots again")
        }
    }

    /// Keeps the newest patches of this worktree (the newest one is re-applied on relaunch).
    static func prunePatches(ws: Workspace) {
        let dir = "\(ws.work)/patches"
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let modules = files.filter { $0.hasSuffix(".dylib") }
            .sorted { mtime("\(dir)/\($0)") > mtime("\(dir)/\($1)") }
            .map { String($0.dropLast(".dylib".count)) }
        for old in modules.dropFirst(keepPatches) {
            for f in files where f == "\(old).dylib" || f.hasPrefix("\(old)_") || f == "\(old).json" {
                try? fm.removeItem(atPath: "\(dir)/\(f)")
            }
        }
    }

    /// Runs a build, and if it failed on a damaged compilation cache (an
    /// entry left half-written, by a full disk for one), clears the cache and
    /// builds once more.
    static func retryingPoisonedCache(_ build: () throws -> Shell.Result) rethrows -> Shell.Result {
        let r = try build()
        guard r.code != 0, r.out.contains("cache poisoned") || r.out.contains("caching backend error") else { return r }
        Log.step("the shared compilation cache is damaged; clearing it and building again")
        try? FileManager.default.removeItem(atPath: "\(Paths.cache)/CompilationCache")
        return try build()
    }

    /// Everything simless keeps, across worktrees, in GB: SIMLESS_DISK_LIMIT_GB,
    /// then the project's `diskLimitGB`, then 25.
    static func diskLimitGB(_ ws: Workspace? = nil) -> Double {
        env("SIMLESS_DISK_LIMIT_GB") ?? (ws ?? (try? Workspace.load()))?.config.diskLimitGB ?? 25
    }

    static func sizeGB(_ path: String) -> Double {
        guard exists(path), let out = try? Shell.run(["/usr/bin/du", "-sk", path], useXcode: false).out,
              let kb = Double(out.split(separator: "\t").first ?? "") else { return 0 }
        return kb / 1_048_576
    }

    /// Keeps the whole cache under the limit: the builds and slots of the
    /// worktrees that used simless least recently go first (`simless up` there
    /// makes them again), then the shared compilation cache. The current
    /// worktree's are kept.
    static func enforceDiskLimit(keeping current: Workspace) {
        let limit = diskLimitGB(current)
        var total = sizeGB(Paths.cache)
        guard total > limit else { return }
        let work = "\(Paths.cache)/work"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [])
            // Not one in use: another session may be testing there right now.
            .filter { "\(work)/\($0)" != current.work && Date().timeIntervalSinceReferenceDate - lastUsed("\(work)/\($0)") > 3600 }
            .sorted { lastUsed("\(work)/\($0)") < lastUsed("\(work)/\($1)") }
        for name in names where total > limit {
            let dir = "\(work)/\(name)"
            _ = try? withLock(GlobalState.lockName(hash: String(name.prefix { $0 != "-" }))) {
                let owner = (try? String(contentsOfFile: "\(dir)/worktree.txt", encoding: .utf8)) ?? dir
                // The folder holds the worktree's slots too.
                let freed = sizeGB(dir)
                for slot in GlobalState.load(path: "\(dir)/state.json").slots { removeSlot(slot) }
                try? FileManager.default.removeItem(atPath: dir)
                total -= freed
                Log.step(String(format: "disk: simless was over %.0f GB, freed %.1f GB of builds for %@ (used least recently)", limit, freed, owner))
            }
        }
        if total > limit {
            let freed = sizeGB("\(Paths.cache)/CompilationCache")
            try? FileManager.default.removeItem(atPath: "\(Paths.cache)/CompilationCache")
            Log.step(String(format: "disk: simless was over %.0f GB, cleared the shared compilation cache (%.1f GB)", limit, freed))
        }
    }

    private static func lastUsed(_ workDir: String) -> Double {
        exists("\(workDir)/last-used") ? mtime("\(workDir)/last-used") : mtime(workDir)
    }

    /// The shared compile cache only speeds up first builds; drop it when large.
    static func capCompileCache() {
        let path = "\(Paths.cache)/CompilationCache"
        guard exists(path), let out = try? Shell.run(["/usr/bin/du", "-sk", path], useXcode: false).out,
              let kb = Double(out.split(separator: "\t").first ?? "") else { return }
        if kb / 1_048_576 > compileCacheLimitGB {
            Log.step(String(format: "shared compile cache is %.1f GB; clearing it", kb / 1_048_576))
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Generated build-variant files next to the user's project.
    static func removeGenerated(ws: Workspace) {
        let fm = FileManager.default
        for dir in Set([ws.root, ws.projectDir]) {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where f.hasSuffix(".simless.xcodeproj") || f.hasSuffix(".simless.xctestplan") {
                try? fm.removeItem(atPath: "\(dir)/\(f)")
            }
        }
    }

    /// `simless clean`: this worktree. `simless clean --all`: everything simless created except
    /// the agent and the files in your repos (SimlessKit, fixtures, config).
    static func clean(all: Bool) throws {
        if all {
            let slots = GlobalState.all()
            for slot in slots { removeSlot(slot) }
            removeCrashReports(olderThan: 0)
            // Every worktree simless built for (slot records and build-cache owner
            // markers), so generated project variants go too.
            let work = "\(Paths.cache)/work"
            var worktrees = Set(slots.map(\.worktree))
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [] {
                if let owner = try? String(contentsOfFile: "\(work)/\(dir)/worktree.txt", encoding: .utf8) { worktrees.insert(owner) }
            }
            for root in worktrees where exists("\(root)/\(Workspace.configName)") {
                if let ws = try? Workspace.load(at: root) { removeGenerated(ws: ws) }
            }
            let fm = FileManager.default
            for item in (try? fm.contentsOfDirectory(atPath: Paths.cache)) ?? [] {
                try? fm.removeItem(atPath: "\(Paths.cache)/\(item)")
            }
            print("removed all simless hosts, slots and caches (\(Paths.cache))")
        } else {
            let ws = try Workspace.load()
            // Every slot of the worktree, an old bundle id's too: deleting the
            // work folder below deletes their records and folders.
            for slot in GlobalState.load(worktree: ws.root).slots {
                removeSlot(slot)
                try GlobalState.release(slot)
            }
            try? FileManager.default.removeItem(atPath: ws.work)
            removeGenerated(ws: ws)
            print("removed this worktree's host, slot and build cache")
        }
    }

    /// `simless clean --worktree <path>`: one worktree's hosts, slots and build
    /// cache, found by its path, so it works after the worktree is removed.
    static func clean(worktree path: String) throws {
        let root = canonicalPath(path)
        // A path spelled unlike the worktree's own root has no folder: say so,
        // rather than report a cleanup that left its hosts running.
        guard exists(Paths.workDir(forWorktree: root)) else {
            throw SimlessError("simless has nothing for \(root); pass the folder that holds \(Workspace.configName)")
        }
        try withLock(GlobalState.lockName(forWorktree: root)) {
            for slot in GlobalState.load(worktree: root).slots { removeSlot(slot) }
            try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: root))
        }
        // A config that doesn't load throws, so generated files don't stay unreported.
        if exists("\(root)/\(Workspace.configName)") { removeGenerated(ws: try Workspace.load(at: root)) }
        print("removed the hosts, slots and build cache of \(root)")
    }
}

/// `path` as git names a worktree: absolute, with symlinks resolved. A part
/// that no longer exists is kept as written, under its resolved parent.
func canonicalPath(_ path: String) -> String {
    let p = URL(fileURLWithPath: path).standardizedFileURL.path
    if let r = realpath(p, nil) {
        defer { free(r) }
        return String(cString: r)
    }
    let parent = (p as NSString).deletingLastPathComponent
    guard parent != p else { return p }
    return (canonicalPath(parent) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
}
