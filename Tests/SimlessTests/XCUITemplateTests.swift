// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// simless's XCUITest API (Templates/XCUI), compiled as `simless test ui`
/// compiles a UI test bundle, and run with `xcrun xctest` against a stand-in
/// host that answers on the bundle's port. Building the bundle takes swiftc,
/// so it runs only with SIMLESS_SLOW_TESTS=1.
final class XCUITemplateTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMLESS_SLOW_TESTS"] == "1", "set SIMLESS_SLOW_TESTS=1 to build a UI test bundle with swiftc")
        dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// The calls of an iOS UI test: wait(for:toEqual:timeout:) from a test and
    /// from a closure, and snapshot() of the app and of one element.
    static let probe = """
        import XCTest

        final class ProbeUITests: XCTestCase {
            @MainActor
            func testWaitSeesTheLabelChange() {
                let title = XCUIApplication().staticTexts["title"]
                XCTAssertEqual(title.label, "Loading")
                let until: () -> Bool = { title.wait(for: \\.label, toEqual: "Ready", timeout: 5) }
                XCTAssertTrue(until())
                XCTAssertTrue(XCUIApplication().switches["toggle"].wait(for: \\.isEnabled, toEqual: false, timeout: 1))
            }

            @MainActor
            func testWaitEndsAtTheTimeout() {
                let start = Date()
                XCTAssertFalse(XCUIApplication().staticTexts["title"].wait(for: \\.label, toEqual: "Never", timeout: 0.5))
                XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5)
                XCTAssertFalse(XCUIApplication().buttons["missing"].wait(for: \\.isHittable, toEqual: true, timeout: 0.2))
            }

            @MainActor
            func testSnapshotHoldsTheTree() throws {
                let app = XCUIApplication()
                let root: XCUIElementSnapshot = try app.snapshot()
                XCTAssertEqual(root.elementType, .application)
                XCTAssertEqual(root.children.map(\\.identifier), ["screen"])
                var all: [any XCUIElementSnapshot] = []
                var pending = [root]
                while let node = pending.popLast() {
                    all.append(node)
                    pending.append(contentsOf: node.children)
                }
                XCTAssertEqual(Set(all.map(\\.identifier)), ["", "screen", "title", "toggle"])
                let toggle = try XCTUnwrap(all.first { $0.identifier == "toggle" })
                XCTAssertEqual(toggle.elementType, .switch)
                XCTAssertEqual(toggle.value as? String, "1")
                XCTAssertEqual(toggle.frame, CGRect(x: 10, y: 100, width: 51, height: 31))
                XCTAssertTrue(app.frame.contains(toggle.frame))
                XCTAssertFalse(toggle.isEnabled)
                XCTAssertTrue(toggle.isSelected)
                XCTAssertEqual(toggle.dictionaryRepresentation[.identifier] as? String, "toggle")
                XCTAssertEqual(toggle.dictionaryRepresentation[.elementType] as? NSNumber, NSNumber(value: XCUIElement.ElementType.switch.rawValue))
                XCTAssertEqual(toggle.dictionaryRepresentation[.enabled] as? NSNumber, false)
                XCTAssertEqual((root.dictionaryRepresentation[.children] as? [[XCUIElement.AttributeName: Any]])?.count, 1)

                let screen = try app.otherElements["screen"].snapshot()
                XCTAssertEqual(screen.children.map(\\.identifier), ["title", "toggle"])
                XCTAssertEqual(screen.children.first?.label, "Loading")
                XCTAssertThrowsError(try app.buttons["missing"].snapshot())
            }
        }
        """

    func testWaitAndSnapshotAgainstAHost() throws {
        let host = try FakeHost()
        defer { host.stop() }
        let bundle = try build(source: Self.probe)
        for test in ["testWaitSeesTheLabelChange", "testWaitEndsAtTheTimeout", "testSnapshotHoldsTheTree"] {
            host.reset()
            let r = try Shell.run(["xcrun", "xctest", "-XCTest", "ProbeUITests/\(test)", bundle],
                                  env: ["SIMLESS_UI_PORT": String(host.port), "SIMLESS_UI_SLOT": "simless.tests.none"])
            XCTAssertEqual(r.code, 0, "\(test):\n\(r.out)")
        }
    }

    func testSnapshotThrowsWhenNoAppAnswers() throws {
        let source = """
            import XCTest

            final class ProbeUITests: XCTestCase {
                @MainActor
                func testNoApp() {
                    XCTAssertThrowsError(try XCUIApplication().snapshot())
                }
            }
            """
        let bundle = try build(source: source)
        let r = try Shell.run(["xcrun", "xctest", bundle], env: ["SIMLESS_UI_PORT": String(try osFreePort()), "SIMLESS_UI_SLOT": "simless.tests.none"])
        XCTAssertEqual(r.code, 0, r.out)
    }

    /// Each TCC service the resources name is one `tccutil` resets, and
    /// resetAuthorizationStatus runs it under SIMLESS_PERMISSIONS=ask. The
    /// resets go to a throwaway app registered with Launch Services for the
    /// test, which has no rows in the TCC store, so the store stays as it was.
    func testProtectedResourcesResetTheirTCCService() throws {
        let source = """
            import XCTest

            final class ProbeUITests: XCTestCase {
                static let all: [XCUIProtectedResource] = [.contacts, .calendar, .reminders, .photos, .microphone, .camera,
                    .mediaLibrary, .homeKit, .focus, .localNetwork, .bluetooth, .keyboardNetwork, .location, .health, .userTracking]

                func testPrintServices() {
                    for r in Self.all { print("tcc \\(r.rawValue) \\(r.tccService ?? "none")") }
                }

                @MainActor
                func testReset() {
                    for r in Self.all { XCUIApplication().resetAuthorizationStatus(for: r) }
                }
            }
            """
        let bundle = try build(source: source)
        let printed = try Shell.run(["xcrun", "xctest", "-XCTest", "ProbeUITests/testPrintServices", bundle])
        XCTAssertEqual(printed.code, 0, printed.out)
        let services = Dictionary(uniqueKeysWithValues: printed.out.split(separator: "\n").compactMap { line -> (Int, String)? in
            let f = line.split(separator: " ")
            guard f.count == 3, f[0] == "tcc", let raw = Int(f[1]) else { return nil }
            return (raw, String(f[2]))
        })
        XCTAssertEqual(services, [1: "AddressBook", 2: "Calendar", 3: "Reminders", 4: "Photos", 5: "Microphone", 6: "Camera",
                                  7: "MediaLibrary", 8: "Willow", 9: "FocusStatus", -1073741829: "none", -1073741824: "BluetoothAlways",
                                  -1073741825: "none", -1073741826: "none", -1073741827: "none", -1073741828: "UserTracking"])

        let id = "simless.tests.tcc-\(UUID().uuidString)"
        // Launch Services finds no app under the temporary folder, so this one
        // goes in the package's build folder.
        let appDir = "\(Paths.toolRoot)/.build/simless-tests-\(UUID().uuidString)"
        let app = "\(appDir)/TCCProbe.app"
        try FileManager.default.createDirectory(atPath: "\(app)/Contents/MacOS", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: appDir) }
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: "\(app)/Contents/MacOS/TCCProbe")
        let info: [String: Any] = ["CFBundleExecutable": "TCCProbe", "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: "\(app)/Contents/Info.plist"))
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try Shell.check([lsregister, "-f", app])
        defer { _ = try? Shell.run([lsregister, "-u", app]) }

        for service in Set(services.values).subtracting(["none"]).sorted() {
            let r = try Shell.run(["/usr/bin/tccutil", "reset", service, id])
            XCTAssertEqual(r.code, 0, "\(service): \(r.out)")
        }
        let reset = try Shell.run(["xcrun", "xctest", "-XCTest", "ProbeUITests/testReset", bundle],
                                  env: ["SIMLESS_PERMISSIONS": "ask", "SIMLESS_UI_SLOT": id])
        XCTAssertEqual(reset.code, 0, reset.out)
        // By default nothing is stored, so nothing runs: an unknown slot fails no test.
        let none = try Shell.run(["xcrun", "xctest", "-XCTest", "ProbeUITests/testReset", bundle],
                                 env: ["SIMLESS_PERMISSIONS": "", "SIMLESS_UI_SLOT": "simless.tests.none"])
        XCTAssertEqual(none.code, 0, none.out)
    }

    /// The bundle as UITestEngine.build makes it: the platform conditions
    /// rewritten, the same swiftc command, Swift 6.
    private func build(source: String) throws -> String {
        let src = "\(dir!)/ProbeUITests.swift"
        try PlatformConditions.rewrite(source).write(toFile: src, atomically: true, encoding: .utf8)
        let shim = try FileManager.default.contentsOfDirectory(atPath: "\(Paths.toolRoot)/Templates/XCUI")
            .filter { $0.hasSuffix(".swift") }.map { "\(Paths.toolRoot)/Templates/XCUI/\($0)" }
        let bundle = "\(dir!)/ProbeUITests.xctest"
        try FileManager.default.createDirectory(atPath: "\(bundle)/Contents/MacOS", withIntermediateDirectories: true)
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = UITestEngine.bundleCommand(module: TestEngine.moduleName("ProbeUITests"), macOS: UITestEngine.macOSVersion(packages: []),
                                                 sdk: sdk, swiftVersion: "6",
                                                 platform: "\(RuntimeBuild.developerDir)/Platforms/MacOSX.platform/Developer",
                                                 output: "\(bundle)/Contents/MacOS/ProbeUITests", packages: [], sources: [src] + shim)
        let r = try Shell.run(command)
        XCTAssertEqual(r.code, 0, r.out)
        let info: [String: Any] = ["CFBundleExecutable": "ProbeUITests", "CFBundleIdentifier": "simless.tests.ProbeUITests",
                                   "CFBundlePackageType": "BNDL", "NSPrincipalClass": "SimlessXCUIObserver"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: "\(bundle)/Contents/Info.plist"))
        return bundle
    }
}

/// Answers the bundle's requests as SimlessRuntime does, one JSON line each,
/// with a fixed tree: the title reads "Loading" for its first 10 snapshots,
/// then "Ready".
private final class FakeHost: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let snapshots = Locked(0)
    private let stopped = Locked(false)

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound, listen(fd, 8) == 0 else { close(fd); throw SimlessError("the fake host could not listen") }
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func reset() { snapshots.mutate { $0 = 0 } }

    func stop() {
        stopped.mutate { $0 = true }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func acceptLoop() {
        while !stopped.value {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { return }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                var reply = answer(request)
                reply["rid"] = request["rid"]
                guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
                data.append(0x0A)
                let wrote = data.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
                guard wrote == data.count else { return }
            }
        }
    }

    private func answer(_ request: [String: Any]) -> [String: Any] {
        guard request["cmd"] as? String == "ui.snapshot" else { return ["ok": true] }
        var count = 0
        snapshots.mutate { $0 += 1; count = $0 }
        let other = Int(XCUIElementTypeRaw.other), text = Int(XCUIElementTypeRaw.staticText), toggle = Int(XCUIElementTypeRaw.switch)
        return ["generation": count, "nodes": [
            ["ref": 0, "parent": -1, "type": other, "id": "screen", "frame": [0, 0, 402, 874], "hittable": true],
            ["ref": 1, "parent": 0, "type": text, "id": "title", "label": count > 10 ? "Ready" : "Loading", "frame": [10, 60, 200, 20], "hittable": true],
            ["ref": 2, "parent": 0, "type": toggle, "id": "toggle", "value": "1", "frame": [10, 100, 51, 31],
             "enabled": false, "selected": true, "hittable": true],
        ]]
    }
}

/// XCUIElement.ElementType raw values that the fake host sends.
private enum XCUIElementTypeRaw {
    static let other: UInt = 1
    static let staticText: UInt = 48
    static let `switch`: UInt = 40
}
