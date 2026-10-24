// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// The render server, for an app that carries no SimlessKit. simless sets
// SIMLESS_RENDER_SERVER=1 on such a render host, and launches it with
// `--simless-port <n>`. The server hides the app, serves render requests over
// 127.0.0.1 with the kit's protocol, and loads the dylibs simless compiles
// (fixtures, previews, hot-reload patches). Those dylibs `import
// SimlessRuntime` and fill the SimlessRegistry defined here. An app that
// carries the kit serves renders itself, and simless leaves the variable unset.
import SwiftUI
import UIKit
import Network

/// Fixtures are registered by `simlessFixtures(_:)` in SimlessFixtures.swift,
/// when the app has that file, and by the fixtures simless generates from
/// `#Preview` blocks.
@MainActor
public final class SimlessRegistry {
    public private(set) var names: [String] = []
    private var makers: [String: () -> AnyView] = [:]

    public init() {}

    /// Registers a screen in a deterministic state. Later registrations of the
    /// same name replace earlier ones.
    public func add<V: View>(_ name: String, _ make: @escaping () -> V) {
        if makers[name] == nil { names.append(name) }
        makers[name] = { AnyView(make()) }
    }

    func make(_ name: String) -> AnyView? { makers[name]?() }
}

@MainActor
enum SimlessHost {
    private static var registry = SimlessRegistry()
    private static var patchGeneration = 0
    private static var renders = 0
    private static var listener: NWListener?
    private static var window: UIWindow?
    private static var lastRequest = Date()
    /// Exit after this long without requests, so a forgotten host never lingers.
    private static var idleLimit: TimeInterval = 1800
    /// The language simless launched this host with (`--locale`), if any.
    private static var launchLocale: String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: "--simless-locale").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    /// The kit protocol version this server speaks: `kitVersion` of
    /// Templates/SimlessKit.swift, which `stats` reports as `kit`.
    static let kitVersion = 6

    /// Called from the runtime's constructor, before `main`, when
    /// SIMLESS_RENDER_SERVER=1. AppKit and UIKit may not be loaded yet, so
    /// window ordering is suppressed as AppKit loads (Headless), and the
    /// server starts on the first turn of the main queue. Fixtures arrive with
    /// the first dylib simless loads (`load`).
    nonisolated static func startIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let port = args.firstIndex(of: "--simless-port").flatMap({ i in i + 1 < args.count ? UInt16(args[i + 1]) : nil })
        else { return runtimeLog("SIMLESS_RENDER_SERVER is set, but no --simless-port; no render server") }
        consumeSandboxExtensions(args)
        Headless.install()
        let idle = args.firstIndex(of: "--simless-idle").flatMap { j in j + 1 < args.count ? TimeInterval(args[j + 1]) : nil }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let idle { idleLimit = idle }
                start(port: port)
            }
        }
    }

    private static func start(port: UInt16) {
        goHeadless()
        removeStalePatches()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { if Date().timeIntervalSince(lastRequest) > idleLimit { exit(0) } }
        }
        enableAccessibilityAutomation()
        loadBundledPatch()
        _ = renderWindow()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            // The listener runs on the main queue, so its handler is already on the main actor.
            l.newConnectionHandler = { conn in MainActor.assumeIsolated { Client(conn).start() } }
            l.start(queue: .main)
            listener = l
            runtimeLog("render server on 127.0.0.1:\(port)")
        } catch {
            exit(75)   // port unavailable: let `simless` notice and retry elsewhere
        }
    }

    // MARK: - Protocol: newline-delimited JSON

    private struct Request: Decodable {
        let cmd: String
        var fixture: String?
        var style: String?
        var width: Double?
        var height: Double?
        var safeTop: Double?       // emulated safe area (Mac only; a simulator has real ones)
        var safeBottom: Double?
        var image: Bool?
        var file: String?
        var textSize: String?      // Dynamic Type: xs … xxxl, ax1 … ax5
        var idiom: String?         // "phone": report the phone idiom (Mac only; see render)
        var settleMs: Double?      // time for the screen's async work (.task, loads, animations) before it's read
    }

    private struct Node: Encodable {
        let role: String?
        let label: String?
        let value: String?
        let id: String?
        let frame: [Double]
        var system: Bool?          // UIKit's own control (e.g. a bar button); its size isn't the app's to fix
        var placeholder: String?   // a text field's
    }

    private struct Traits: Encodable {
        let horizontalSizeClass: String
        let verticalSizeClass: String
        let idiom: String          // what the view's trait collection reports
        let deviceIdiom: String    // UIDevice.current.userInterfaceIdiom (SimlessRuntime makes it follow the phone idiom)
        let safeArea: [Double]     // top, left, bottom, right
        let onMac: Bool
        var textSize: String?
    }

    private struct Response: Encodable {
        var ok = true
        var error: String?
        var pid: Int32?
        var tmp: String?
        var fixtures: [String]?
        var patch: Int?
        var renders: Int?
        var footprintMB: Double?
        var fixture: String?
        var renderMs: Double?
        var nodes: [Node]?
        var png: String?
        var loadMs: Double?
        var traits: Traits?
        var locale: String?        // the host's language (simless relaunches it to switch)
        var screen: [Double]?      // device screen and safe area (calibration reads the simulator's)
        var kit: Int?
    }

    /// One client connection. Network delivers its callbacks on the main queue,
    /// so the connection's state lives on the main actor: each callback enters it
    /// synchronously, and nothing mutable is shared across isolation domains
    /// (this compiles under Swift 6 with any default isolation).
    @MainActor
    private final class Client {
        private let conn: NWConnection
        private var buffer = Data()

        init(_ conn: NWConnection) { self.conn = conn }

        func start() {
            conn.start(queue: .main)
            receive()
        }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
                MainActor.assumeIsolated {
                    if let data { buffer.append(data) }
                    drain()
                    if done || err != nil { conn.cancel() } else { receive() }
                }
            }
        }

        private var waiting = false

        private func drain() {
            while !waiting, let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                // A render answers after the main queue has turned (see renderSettled);
                // the requests after it wait.
                if let req = try? JSONDecoder().decode(Request.self, from: line), req.cmd == "render" {
                    waiting = true
                    SimlessHost.lastRequest = Date()
                    SimlessHost.renderSettled(req) { [self] response in
                        send(response, nil)
                        waiting = false
                        drain()
                    }
                    return
                }
                // `simless act`: UI commands go to SimlessRuntime, which answers later.
                if let req = try? JSONDecoder().decode(Request.self, from: line), req.cmd.hasPrefix("ui.") {
                    waiting = true
                    SimlessHost.lastRequest = Date()
                    SimlessHost.forwardToRuntime(line) { [self] reply in
                        var out = reply
                        out.append(0x0A)
                        conn.send(content: out, completion: .contentProcessed { _ in })
                        waiting = false
                        drain()
                    }
                    return
                }
                let (response, after) = SimlessHost.handle(line)
                send(response, after)
            }
        }

        private func send(_ response: Response, _ after: (@Sendable () -> Void)?) {
            var out = (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
            out.append(0x0A)
            conn.send(content: out, completion: .contentProcessed { _ in after?() })
        }
    }

    private static func handle(_ line: Data) -> (Response, (@Sendable () -> Void)?) {
        lastRequest = Date()
        guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
            return (Response(ok: false, error: "bad request"), nil)
        }
        switch req.cmd {
        case "stats":
            var r = Response(pid: getpid(), tmp: FileManager.default.temporaryDirectory.path,
                             fixtures: registry.names, patch: patchGeneration, renders: renders,
                             footprintMB: footprintMB())
            r.locale = launchLocale
            r.kit = kitVersion
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                let b = scene.screen.bounds, s = scene.windows.first?.safeAreaInsets ?? .zero
                r.screen = [b.width, b.height, s.top, s.bottom].map { Double($0) }
            }
            return (r, nil)
        case "render":
            return (render(req), nil)
        case "tree":
            // The screen as it is now, after `simless act` interacted with it.
            guard let m = mounted else { return (Response(ok: false, error: "nothing rendered yet"), nil) }
            m.host.view.layoutIfNeeded()
            return (finish(Mounted(name: m.name, host: m.host, rect: m.rect, start: CFAbsoluteTimeGetCurrent()), req), nil)
        case "load":
            return (load(req), nil)
        case "stop":
            // Reply first, then exit.
            return (Response(), { exit(0) })
        default:
            return (Response(ok: false, error: "unknown cmd \(req.cmd)"), nil)
        }
    }

    // MARK: - Rendering

    /// The window fixtures render into, created on first use. It belongs to the
    /// app's scene: `UIWindow(frame:)` is deprecated since iOS 26, and an app
    /// that treats warnings as errors refuses it. On the Mac the host runs
    /// headless, so the window shows on no screen. In a simulator (`simless calibrate`) it goes on top, so the
    /// device's own safe areas and traits apply. The scene may connect after
    /// the host starts, hence the lazy creation.
    ///
    /// On the Mac with no login session (SSH, a LaunchDaemon) no scene ever
    /// connects, and a window with no scene still lays SwiftUI out. It is made
    /// through `NSObject.Type`, whose `init()` carries no deprecation, so the
    /// deprecated `UIWindow()` isn't named.
    private static func renderWindow() -> UIWindow? {
        if let window { return window }
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        let w: UIWindow
        if let scene {
            w = UIWindow(windowScene: scene)
        } else if ProcessInfo.processInfo.isiOSAppOnMac {
            w = (UIWindow.self as NSObject.Type).init() as! UIWindow
        } else {
            return nil
        }
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            w.isHidden = false
        } else {
            w.windowLevel = .alert + 1
            w.makeKeyAndVisible()
        }
        window = w
        return window
    }

    /// A fixture put on the canvas, before its tree is read.
    private struct Mounted {
        let name: String
        let host: UIHostingController<AnyView>
        let rect: CGRect
        let start: CFAbsoluteTime
    }

    /// Hands a `ui.*` request to UI automation, with the canvas it acts in.
    /// The reply comes on the main thread.
    fileprivate static func forwardToRuntime(_ line: Data, _ done: @escaping (Data) -> Void) {
        let box = Unmanaged.passRetained(ReplyBox(done)).toOpaque()
        let canvas = window.map { Unmanaged.passUnretained($0).toOpaque() }
        String(decoding: line, as: UTF8.self).withCString { json in
            simlessRuntimeUI(json, canvas, box) { reply, context in
                guard let context else { return }
                let box = Unmanaged<ReplyBox>.fromOpaque(context).takeRetainedValue()
                box.done(Data(reply.map { String(cString: $0) }?.utf8 ?? #"{"ok":false}"#.utf8))
            }
        }
    }

    private final class ReplyBox {
        let done: (Data) -> Void
        init(_ done: @escaping (Data) -> Void) { self.done = done }
    }

    private static func iOSColor(_ light: Int, dark: Int) -> UIColor {
        func color(_ rgb: Int) -> UIColor {
            UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        return UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
    }

    private static let appAccent: UIColor = (Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String)
        .flatMap { UIColor(named: $0) } ?? UIColor(named: "AccentColor") ?? iOSColor(0x007AFF, dark: 0x0A84FF)

    /// The fixture on the canvas, for `tree`.
    private static var mounted: Mounted?

    private static func render(_ req: Request) -> Response {
        switch mount(req) {
        case .failure(let r): return r
        case .success(let m):
            // One frame for SwiftUI to commit, then lay out again.
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            m.host.view.layoutIfNeeded()
            return finish(m, req)
        }
    }

    /// A screen that loads asynchronously (`.task`, a load) gets the time it
    /// asked for before its tree is read. Its work runs on the main actor, which
    /// is busy with this request, so the render gives the main queue back in
    /// frames and answers when the time is up.
    private static func renderSettled(_ req: Request, _ reply: @escaping (Response) -> Void) {
        switch mount(req) {
        case .failure(let r): reply(r)
        case .success(let m):
            // SwiftUI fills in some labels (a Menu's custom label on the Mac) only
            // after something has read them once, on a later turn of the main
            // queue. Read once now; the tree is read after that turn.
            _ = collect(m.host.view)
            let until = Date().addingTimeInterval(min((req.settleMs ?? 0) / 1000, 10))
            func frame() {
                m.host.view.layoutIfNeeded()
                if Date() < until {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { MainActor.assumeIsolated { frame() } }
                } else {
                    reply(finish(m, req))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { frame() } }
        }
    }

    private enum MountResult { case success(Mounted), failure(Response) }

    private static func mount(_ req: Request) -> MountResult {
        // The fixtures arrive only with a dylib simless loads. Before the first
        // one, an empty registry says nothing about which fixtures exist.
        guard patchGeneration > 0 else {
            return .failure(Response(ok: false, error: "no fixtures loaded yet: simless loads them into the host after `simless up` compiles them; run `simless up` if this stays"))
        }
        guard let name = req.fixture, let view = registry.make(name) else {
            return .failure(Response(ok: false, error: "unknown fixture '\(req.fixture ?? "")'", fixtures: registry.names))
        }
        guard let window = renderWindow() else {
            return .failure(Response(ok: false, error: "no window to render into yet (the app's scene hasn't connected)"))
        }
        let start = CFAbsoluteTimeGetCurrent()
        let rect = CGRect(x: 0, y: 0, width: req.width ?? 402, height: req.height ?? 874)
        window.frame = rect
        let size = req.textSize.flatMap { textSizes[$0] }
        let host = UIHostingController(rootView: size.map { AnyView(view.environment(\.dynamicTypeSize, $0.swiftUI)) } ?? view)
        host.overrideUserInterfaceStyle = req.style == "dark" ? .dark : .light
        // The hidden window lands on whichever display macOS picks; pin the
        // scale so layout rounding (and PNGs) don't depend on that display.
        host.traitOverrides.displayScale = 2
        // An iOS app on a Mac reports iPad-like traits; give phone canvases a
        // phone's size classes and, on the Mac, the device's safe areas (notch,
        // home indicator). A simulator already has the real ones. The idiom stays
        // iPad unless asked: under .phone on the Mac, SwiftUI's Stepper recurses
        // until the stack overflows.
        let phone = rect.width < 600
        host.traitOverrides.horizontalSizeClass = phone ? .compact : .regular
        host.traitOverrides.verticalSizeClass = .regular
        if let size { host.traitOverrides.preferredContentSizeCategory = size.uiKit }
        // `--idiom phone`: a phone's control metrics and idiom branches.
        if req.idiom == "phone" { host.traitOverrides.userInterfaceIdiom = .phone }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: req.safeTop ?? 0, left: 0, bottom: req.safeBottom ?? 0, right: 0)
            // iOS's colors, not the Mac's accent: the app's accent color when it
            // has one, else iOS blue, and iOS green for switches that are on.
            host.view.tintColor = appAccent
            if UISwitch.appearance().onTintColor == nil { UISwitch.appearance().onTintColor = iOSColor(0x34C759, dark: 0x30D158) }
        }
        window.rootViewController = host
        host.view.frame = rect
        host.view.layoutIfNeeded()
        let m = Mounted(name: name, host: host, rect: rect, start: start)
        mounted = m
        return .success(m)
    }

    /// Reads the mounted fixture's tree (and PNG) into the response.
    private static func finish(_ m: Mounted, _ req: Request) -> Response {
        let (name, host, rect, start) = (m.name, m.host, m.rect, m.start)
        let nodes = collect(host.view)
        var png: String?
        if req.image == true {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let img = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
                host.view.drawHierarchy(in: rect, afterScreenUpdates: true)
            }
            png = img.pngData()?.base64EncodedString()
        }
        renders += 1
        goHeadless()
        let tc = host.traitCollection, insets = host.view.safeAreaInsets
        func sizeClass(_ s: UIUserInterfaceSizeClass) -> String { s == .compact ? "compact" : s == .regular ? "regular" : "unspecified" }
        func idiom(_ i: UIUserInterfaceIdiom) -> String {
            switch i { case .phone: "phone"; case .pad: "pad"; case .mac: "mac"; default: "other" }
        }
        var r = Response(patch: patchGeneration, fixture: name,
                         renderMs: (CFAbsoluteTimeGetCurrent() - start) * 1000, nodes: nodes, png: png)
        r.traits = Traits(horizontalSizeClass: sizeClass(tc.horizontalSizeClass), verticalSizeClass: sizeClass(tc.verticalSizeClass),
                          idiom: idiom(tc.userInterfaceIdiom), deviceIdiom: idiom(UIDevice.current.userInterfaceIdiom),
                          safeArea: [insets.top, insets.left, insets.bottom, insets.right].map { Double($0) },
                          onMac: ProcessInfo.processInfo.isiOSAppOnMac, textSize: req.textSize)
        r.locale = launchLocale
        return r
    }

    private static let textSizes: [String: (uiKit: UIContentSizeCategory, swiftUI: DynamicTypeSize)] = [
        "xs": (.extraSmall, .xSmall), "s": (.small, .small), "m": (.medium, .medium), "l": (.large, .large),
        "xl": (.extraLarge, .xLarge), "xxl": (.extraExtraLarge, .xxLarge), "xxxl": (.extraExtraExtraLarge, .xxxLarge),
        "ax1": (.accessibilityMedium, .accessibility1), "ax2": (.accessibilityLarge, .accessibility2),
        "ax3": (.accessibilityExtraLarge, .accessibility3), "ax4": (.accessibilityExtraExtraLarge, .accessibility4),
        "ax5": (.accessibilityExtraExtraExtraLarge, .accessibility5),
    ]

    // MARK: - Accessibility tree

    /// SwiftUI only vends its accessibility tree to an active assistive client;
    /// automation mode turns that on in-process (the approach KIF uses).
    private static func enableAccessibilityAutomation() {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(h, "_AXSSetAutomationEnabled") else { return }
        typealias Fn = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(true)
    }

    private static func collect(_ root: UIView) -> [Node] {
        var out: [Node] = []
        var seen = Set<ObjectIdentifier>()
        // accessibilityFrame is in screen space; frames are reported relative to the host view.
        let origin = root.accessibilityFrame.origin
        func visit(_ obj: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(obj)).inserted else { return }
            if obj.isAccessibilityElement {
                let cls = String(describing: type(of: obj))
                // A split view's column resize handle: unlabeled, full height, and
                // partly off screen when the sidebar is hidden. Not app content.
                if cls.contains("SplitViewController"), cls.contains("Separator") { return }
                let a = obj.accessibilityFrame
                let id = obj.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                    ? obj.value(forKey: "accessibilityIdentifier") as? String : nil
                let traits = obj.accessibilityTraits
                let field = obj is UITextField || (obj as? UITextView)?.isEditable == true
                out.append(Node(role: field ? "field" : traits.contains(.toggleButton) ? "switch" : role(traits),
                                label: label(of: obj), value: obj.accessibilityValue, id: (id?.isEmpty ?? true) ? nil : id,
                                frame: [a.minX - origin.x, a.minY - origin.y, a.width, a.height]
                                    .map { (Double($0) * 10).rounded() / 10 },
                                system: cls.hasPrefix("_UI") ? true : nil,
                                placeholder: (obj as? UITextField)?.placeholder.flatMap { $0.isEmpty ? nil : $0 }))
                // VoiceOver treats an element as one unit and doesn't descend into it
                // (a Toggle row's switch, a Picker's value text). Neither do we.
                return
            }
            // A container that lists its accessibility elements replaces its
            // subviews for VoiceOver; only fall back to subviews when it lists none.
            var children: [NSObject] = []
            if let elements = obj.accessibilityElements as? [NSObject], !elements.isEmpty {
                children = elements
            } else {
                let n = obj.accessibilityElementCount()
                if n != NSNotFound && n > 0 {
                    for i in 0..<n { if let e = obj.accessibilityElement(at: i) as? NSObject { children.append(e) } }
                }
            }
            if children.isEmpty, let view = obj as? UIView { children = view.subviews }
            for c in children { visit(c, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return out
    }

    /// An element's label. On the Mac a control with a custom label (a Menu
    /// row) can have none, where iOS reads its texts: "Landing page, Chats".
    /// Those texts are its automation elements, as XCUITest sees them.
    private static func label(of obj: NSObject) -> String? {
        if let l = obj.accessibilityLabel, !l.isEmpty { return l }
        // Asking for them is what makes SwiftUI fill in the label, the first time.
        let children = (obj.automationElements as? [NSObject]) ?? []
        if let l = obj.accessibilityLabel, !l.isEmpty { return l }
        let texts = children.compactMap { e -> String? in
            let t = e.accessibilityTraits
            guard t.contains(.staticText), !t.contains(.image), let l = e.accessibilityLabel, !l.isEmpty else { return nil }
            return l
        }
        return texts.isEmpty ? obj.accessibilityLabel : texts.joined(separator: ", ")
    }

    private static func role(_ t: UIAccessibilityTraits) -> String {
        if t.contains(.button) { return "button" }
        if t.contains(.link) { return "link" }
        if t.contains(.searchField) { return "search" }
        if t.contains(.header) { return "header" }
        if t.contains(.image) { return "image" }
        if t.contains(.adjustable) { return "adjustable" }
        if t.contains(.staticText) { return "text" }
        return "element"
    }

    // MARK: - Hot reload

    /// A patch dylib exports `simless_patch_entry(registry)`, which runs the patch's
    /// own copy of `simlessFixtures`, so every fixture is rebuilt from the
    /// edited view code.
    private typealias PatchEntry = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static func apply(_ path: String) -> String? {
        // dlopen of quarantined code blocks on a Gatekeeper prompt, which would
        // hang a headless host. `simless` never produces quarantined patches; refuse
        // rather than hang if one appears anyway.
        if getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 {
            return "patch is quarantined; refusing to load"
        }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return "dlopen: " + String(cString: dlerror())
        }
        guard let sym = dlsym(handle, "simless_patch_entry") else { return "patch has no simless_patch_entry" }
        let fresh = SimlessRegistry()
        unsafeBitCast(sym, to: PatchEntry.self)(Unmanaged.passUnretained(fresh).toOpaque())
        registry = fresh
        patchGeneration += 1
        return nil
    }

    /// Live: `simless` (via SimlessAgent) placed the patch in our tmp dir.
    private static func load(_ req: Request) -> Response {
        guard let file = req.file, !file.contains("/") else {
            return Response(ok: false, error: "load needs a file name")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(file).path
        if let error = apply(path) { return Response(ok: false, error: error) }
        unlink(path)   // the code stays mapped; the file is no longer needed
        return Response(patch: patchGeneration, loadMs: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Live patches left over from a previous host process.
    private static func removeStalePatches() {
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        where f.hasPrefix("SimlessPatch") && f.hasSuffix(".dylib") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(f))
        }
    }

    /// Warm: the patch was installed inside the app bundle (never quarantined).
    private static func loadBundledPatch() {
        let dir = Bundle.main.bundleURL.appendingPathComponent("SimlessPatches")
        let newest = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".dylib") }.sorted().last
        if let newest { _ = apply(dir.appendingPathComponent(newest).path) }
    }

    // MARK: - Sandbox

    /// Render hosts get their read-only sandbox extension as an argument
    /// (`--simless-sandbox`); the runtime already consumes the environment's.
    nonisolated private static func consumeSandboxExtensions(_ args: [String]) {
        let tokens = args.indices.filter { args[$0] == "--simless-sandbox" && $0 + 1 < args.count }.map { args[$0 + 1] }
        guard !tokens.isEmpty else { return }
        consumeSandboxTokens(tokens.joined(separator: "\n"))
    }

    // MARK: - Headless

    /// Reaches the AppKit NSApplication underneath the iOS app: no Dock icon,
    /// never active, windows hidden. Rendering is unaffected.
    private static func goHeadless() { Headless.hide() }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
    }
}
