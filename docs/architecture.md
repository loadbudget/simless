# Architecture

simless gives coding agents a fast, headless way to check SwiftUI screens and run unit and UI tests without the iOS Simulator. This document explains how it works. [findings.md](findings.md) explains why it works this way.

```
 agent ──► simless CLI ──► xcodebuild (generic/platform=iOS, unsigned)
              │                 │
              │                 ▼
              │          slot: <bundle id>.simlessN   (APFS clone, retagged Mac Catalyst,
              │                 │                      signed ad hoc, LSUIElement)
              │                 │  started directly (posix_spawn), home folder in the slot
              │                 ▼
              ├──── TCP ───► render host = your app, hidden, running SimlessRuntime (+ SimlessKit, if the app has it)
              │                 ▲
              └─ patch dylib ───┘ copied into the host's tmp, dlopen'd
```

That's the native mode, the default. The `dfi` mode (`"mode": "dfi"`) is what simless did before: a "Designed for iPad" build, re-signed with the team's wildcard development profile, installed through xcodebuild, running in the app sandbox, with SimlessAgent placing patches. Sections 1 and 2 describe both. The rest is the same for both modes.

## 0. The native mode: no signing, no install

An iOS device binary and a Mac Catalyst binary are the same arm64 code against the same frameworks (`/System/iOSSupport`). What differs is one field, the platform in each Mach-O's `LC_BUILD_VERSION`: macOS runs a binary tagged iOS only as a provisioned "Designed for iPad" install, and runs one tagged Mac Catalyst like any Mac program, signed ad hoc. So simless:

- builds the plain iOS device slice (`generic/platform=iOS`), which needs no Mac destination and so works in a VM too, and no project variant.
- clones the app into the slot and rewrites the platform field of every iOS-tagged Mach-O in it (main executable, debug dylib, frameworks, test bundles) to Mac Catalyst, in place: a few bytes per binary (`MachO.swift`, with `vtool` for old binaries that only have `LC_VERSION_MIN_IPHONEOS`).
- makes the clone writable (a binary xcframework from a SwiftPM checkout is read-only, and its build product keeps that), never the build itself.
- adds `/System/iOSSupport/usr/lib/swift` as the last rpath of a binary that loads a Swift library through `@rpath` which only Mac Catalyst has (`libswiftCoreNFC` in a framework built for an old iOS). Every slot preparation applies it again, so `clean` and a cold `up` get it too.
- signs what changed ad hoc (`codesign -s -`): no identity, no keychain, no profile.
- starts the executable directly with `posix_spawn`, in a session of its own, with the runtime in `DYLD_INSERT_LIBRARIES`. No xcodebuild install, no LaunchServices, no window server session needed.

The app now runs outside the app sandbox, so simless gives it what the sandbox gave it:

| What the app sees | How |
|---|---|
| Its own home, documents, caches, tmp | `CFFIXED_USER_HOME` and `HOME` point into the slot, and SimlessRuntime interposes `confstr` for the per-user temp and cache folders, which `NSTemporaryDirectory` reads |
| Its own preferences | the standard domain is the slot's id, and `UserDefaults(suiteName:)` suites are renamed under it |
| A keychain | SimlessRuntime interposes `SecItemAdd`/`CopyMatching`/`Update`/`Delete` with a store in the slot's home. The real keychain refuses an app without an application identifier (`errSecMissingEntitlement`) |
| `isiOSAppOnMac == true` | as for a "Designed for iPad" app, since SimlessKit and apps branch on it |
| An iOS process's malloc, in render hosts | `MallocSpaceEfficient=1`. A Mac process keeps freed pages, and without it a render host grew ~20 MB more over a few dozen renders. It costs CPU-bound code ~4%, so test hosts, which are short-lived and CPU-bound, run without it |

On a machine shared by many projects, `"isolate": true` (or `SIMLESS_ISOLATE=1`) gives each native host a sandbox of its own. SimlessRuntime applies it in its constructor, before any of the app's code runs (`sandbox_init_with_parameters`, the mechanism behind `sandbox-exec`, which needs no entitlement): writes only into the slot, reads in the user's home only of the slot, the worktree, its build folder and local packages, and no connections to other hosts' ports. A host that can't be isolated exits instead of running unisolated.

Wiping a slot's data is then a folder delete plus clearing the slot's preferences domains through CFPreferences, so nothing has to launch for it, and live reload copies the patch into the host's tmp itself: an unsandboxed process's files aren't quarantined, so SimlessAgent isn't needed.

## 1. Your app runs natively on the Mac

Apple Silicon Macs run iOS arm64 apps natively. simless builds the app's normal iOS device slice (for `generic/platform=iOS` in the native mode, for the `platform=macOS,arch=arm64,variant=Designed for iPad` destination in the dfi mode):
- **No simulator runtime**, so no SpringBoard or simulator daemons.
- **Third-party SDKs keep working**, because they use the iOS slice they already ship.
- **Your real views, real dependencies, and the real app target.** No porting and no separately written copies of your screens.

In the dfi mode, Xcode hides the Designed-for-iPad destination for targets that also ship native macOS or opt out of it. In that case simless builds from a generated sibling copy of the project (`<Name>.simless.xcodeproj`, next to the original, wherever it is in the repository) with `macosx` removed from `SUPPORTED_PLATFORMS` and Designed for iPad enabled. Shared schemes and test plans are copied and rewritten to point at the copy. The original project is never modified, and the generated files are added to `.git/info/exclude`.

Builds run with `CODE_SIGNING_ALLOWED=NO`. All signing happens when a slot is created (below), so builds never need provisioning and never touch the developer account. Without a unit-test target the build is a plain `build` instead of `build-for-testing`.

## 2. Slots: one copy per worktree

macOS runs one instance per bundle id. Several agents need several hosts, so each worktree gets a **slot**: an APFS clone of the build (near-free). In the native mode it's prepared as in section 0, with the id, Info.plist keys and extension handling below, and is ready to start (about 0.3 s for the demo app). In the dfi mode it's modified as follows:

- `CFBundleIdentifier` becomes `<bundle id>.simless<N>`.
- App extensions (`PlugIns/*.appex`) and the watch app (`Watch/`) stay, with every id in their Info.plists that starts with the app's id moved under the slot's (installd checks that prefix). Each extension gets the profile and its own `application-identifier`. After install, simless sets each extension to "ignore" with `pluginkit`, so a slot's widgets never reach the widget gallery. If an install with them fails, simless installs without them. `"embeddedBundles": false` always removes them.
- `LSUIElement` is set, so the app never shows a Dock icon, not even during launch.
- It's re-signed inside-out with the team's **wildcard development profile** and only `application-identifier`, `team-identifier` and `get-task-allow`. The slot has no capabilities: rendering needs no iCloud, push or app groups. installd rejects any other entitlement the profile doesn't list, sandbox temporary exceptions included.

A slot is installed through a zero-test `xcodebuild test-without-building -only-testing:<UnitTests>/SimlessInstallOnly` run (xcodebuild is the only supported installer for Designed-for-iPad apps), using a copy of the build's `.xctestrun` with the host bundle id swapped. Installs are serialized machine-wide. The host is then launched **by path** (`open -g -j <slot>/.XCInstall/<App>.app --args --simless-port N`), not by bundle id.

## 3. The render host (SimlessKit or SimlessRuntime)

The render server runs in one of two places. `simless up` checks for the app's `SimlessKit.swift` (`<kitDir>/SimlessKit.swift`) as the build starts, and records the answer in the render slot's record with the build. Each later launch of the render host, and each dylib compiled for it, follows the record, not the file on disk:

- **Built with the kit:** the kit serves renders, as described below. simless does not set `SIMLESS_RENDER_SERVER`, and the dylibs it compiles use the kit's `SimlessRegistry` through `@testable import <App>`.
- **Built without the kit:** simless launches the render host with `SIMLESS_RENDER_SERVER=1`. SimlessRuntime reads it in its constructor and starts the same server, with the same protocol, on `--simless-port` (`Runtime/RenderHost.swift`). It logs `simless-runtime: render server on 127.0.0.1:<port>` to the host's log. The runtime build also writes `SimlessRuntime.swiftmodule`. Each slot gets a copy of it with each copy of the runtime it injects, and the fixtures, previews and patch dylibs `import SimlessRuntime` from that copy for its `SimlessRegistry`. The slot records the runtime build it injects (`runtime-build.txt`) and the build of its module copy (`runtime-module/build.txt`). The previews dylib that `simless up` compiles waits for the current runtime build and uses its module, because `up` gives the slot that runtime. A patch compiles against the module of the runtime the slot injects. A relaunch keeps the slot's runtime when another build is current, so the dylibs a host loads always match its runtime. `simless reload` builds the app again when the runtime changed ("SimlessRuntime changed"). They compile for iOS 17.0 or later, the runtime's own target. The fixtures reach the host only in the previews dylib, so `simless up` builds that dylib even when the app has no preview or sets `"previews": false`. `SimlessFixtures.swift` is optional in this mode. When it is there, every one of those dylibs compiles it and calls `simlessFixtures`. When it is not, they leave it out, and the fixtures are `root` and the `#Preview` blocks. With no fixtures file and `"previews": false`, `simless up` stops with an error before it writes anything, so the record of the sources the host runs stays and the next `simless reload` still sees each edit. `simless up` builds the previews dylib before it starts the host, and the launch loads it before `up` reports the host ready. A build or load that fails stops `up` with an error that says why. When the last round of the previews build leaves out every preview, simless builds the dylib with the fixtures alone. In the dfi mode, only SimlessAgent loads a dylib into a host, so with no agent running `up` stops and says to run `simless agent install`. After such a failed `up`, `simless reload` builds the app again ("the fixtures weren't built") instead of patching a host with no fixtures. Until the first dylib loads, the server answers a render with `no fixtures loaded yet`, not with an unknown fixture. The app defines no `SimlessRegistry` in this mode, so the app build that simless runs leaves out each source file named like the fixtures file (`EXCLUDED_SOURCE_FILE_NAMES`), also in a folder Xcode syncs for the app target. Other builds of the app compile the file, so it keeps its `#if SIMLESS` guard. With the kit, `SimlessFixtures.swift` is required, as before: the kit calls `simlessFixtures`. The runtime hides every host that carries `SIMLESS_HEADLESS=1` or `SIMLESS_UI=1`, with or without the kit: see "Every launch is hidden" below.

The variable is set only for a build without the kit, so one server listens on the port. When the kit is added or deleted after a build, `simless reload` builds the app again instead of patching it.

`SimlessKit.swift` is a single `#if SIMLESS` file that older `simless init` runs added to the app, with a call to `SimlessHost.startIfRequested()` in the App's `init()`. `simless init` now writes only `.simless.json`, and removes the kit and that call when each is as simless wrote it and no other code names `SimlessHost`; otherwise it changes no app file and lists each line. It does nothing unless the app is launched with `--simless-port`. When it is, it:

- **Hides the app** when it has `--simless-port` or `SIMLESS_HEADLESS=1` and `isiOSAppOnMac` is true. A native host reports `isiOSAppOnMac` as true too, because SimlessRuntime makes it so before the app's code runs. SimlessRuntime hides the app as well (below).
- **Turns on accessibility automation** in-process (`_AXSSetAutomationEnabled`, the approach KIF uses), so SwiftUI vends its accessibility tree.
- **Calls `simlessFixtures(_:)`**, which the app owns, to register screens.
- **Opens the sandbox a little,** in every run simless starts. It consumes the read-only sandbox extensions simless issued for the repository (`sandbox_extension_issue_file` / `_consume`, the mechanism behind file panels), so tests and fixtures can read repository files. It also points `containerURL(forSecurityApplicationGroupIdentifier:)` at a private folder per group inside the slot's container, because the slot can't hold app-group entitlements.
- **Serves newline-delimited JSON on `127.0.0.1:<port>`**: `stats`, `render`, `load`, `stop`.
- **Exits after 30 idle minutes.**

**Every launch is hidden.** SimlessRuntime hides each host that simless launches, so an app without the kit shows no window either (`Runtime/Headless.swift`):
- as AppKit loads, before any window exists, it makes AppKit's window-ordering calls no-ops.
- on the first turn of the main queue, and each time a window becomes visible, it sets the `NSApplication` activation policy to *prohibited*, calls `hide:`, and makes each window transparent and click-through, all through the ObjC runtime.

It does so when the host carries `SIMLESS_HEADLESS=1` or `SIMLESS_UI=1`, and logs `simless-runtime: headless`. It has no `isiOSAppOnMac` check. A window that is never ordered in may never become the key window, so a unit test that needs a key window or a first responder can fail without the kit. The kit did the same. Each launch gets the runtime and one of the two variables. The `open` and `posix_spawn` launches set `DYLD_INSERT_LIBRARIES` only when the slot has its copy of the runtime (`SimlessRuntime.dylib`). `simless up` and each relaunch put that copy in place first. The install run's `slot.xctestrun` names the copy without that check, and `Slots.prepare` puts the copy in place before the install:

| Launch | How simless starts it | Runtime from | Variable |
| --- | --- | --- | --- |
| Render host | `open --env` (dfi), `posix_spawn` (native) | `DYLD_INSERT_LIBRARIES` | `SIMLESS_HEADLESS` |
| Unit and package test host, standby host | `open --env` (dfi), `posix_spawn` (native) | `DYLD_INSERT_LIBRARIES` | `SIMLESS_HEADLESS` |
| UI test host | the runtime's shim in the `xctest` runner | `DYLD_INSERT_LIBRARIES` | `SIMLESS_UI` |
| Install run (dfi only) | `xcodebuild test-without-building` on `slot.xctestrun` | `DYLD_INSERT_LIBRARIES` in the app-hosted target's `TestingEnvironmentVariables`, after xcodebuild's own libraries. `Slots.install` writes this into the file again before each run, so a file from an older simless gets it too | `SIMLESS_HEADLESS` in `EnvironmentVariables` |
| Wipe of a slot's data | `open --env` | `DYLD_INSERT_LIBRARIES` | none: the runtime exits before the app's code runs |

For the install run, `Slots.install` listens on a loopback port that the OS picks and puts it in `SIMLESS_INSTALL_REPORT`. The runtime, when it hides the app, sends `headless` there. Without the kit, an install with no such report fails, and the error names the `.xctestrun` injection. With the kit, the kit hides the app, so the install passes without the report, as before.

With the kit, the kit hides the app as well, in the same way. Slots are also `LSUIElement` and `LSBackgroundOnly`. Measured result, with the kit: no window, Dock icon or focus change, sampled every 10 ms. `simless calibrate` runs in a simulator and is not in the table.

SimlessRuntime, which every host loads before the app's own code, also takes the network away from render hosts (`Runtime/Network.swift`): a `URLProtocol` registered globally and put first in every new default and ephemeral `URLSessionConfiguration` (sessions with their own configuration only use the protocols it lists) fails each http(s) and ws(s) request with `notConnectedToInternet`, except loopback and what `.simless.json` allows or stubs. Each blocked request is a line in the host's log, which `simless render` sums up per host, so it works in the dfi mode's sandbox too. Test hosts keep the network unless `network.tests` is set.

`render` hosts the fixture in a `UIHostingController`:
- the canvas is sized to the requested device, in light or dark mode.
- phone canvases get compact width and, on the Mac, the device's safe-area insets. iPad canvases get regular width. The traits the view actually saw are returned with every render. The idiom stays `.pad` on the Mac unless the render asks for `.phone` (`--idiom phone`), because SwiftUI's `Stepper` crashes under it. When a render takes the host down, the CLI reads the macOS crash report for the slot (`~/Library/Logs/DiagnosticReports`), reports the exception and first frames in the app or SwiftUI, relaunches the host and carries on. It looks for the report for 4 s. Then a trap or the crash handler's frames in the host's log answer, and without those it looks until 90 s after the first look, because macOS can write the report up to a minute after the crash (52 s in one run). It takes the newest report whose `captureTime` is after the render started. Under `.phone` it first retries the screen with `.pad`. Under `.phone`, SimlessRuntime makes `UIDevice.current.userInterfaceIdiom` report `.phone` while the render's hosting controller is the window's root (Runtime/Idiom.swift).
- `--text-size` sets `preferredContentSizeCategory` and `dynamicTypeSize`. Layout follows them, and text scales too, because SimlessRuntime makes CoreText use iOS's text-style sizes (see [findings.md](findings.md)).
- `--locale` relaunches the host with `-AppleLanguages` and `-AppleLocale`, since the language is process-wide (string lookup, formatters, layout direction).
- `displayScale` is pinned to 2, because the hidden window lands on an arbitrary display.
- it returns the accessibility elements (role, label, value, identifier, frame), plus a PNG if requested.

`simless act` mounts a fixture the same way, then sends the render server `ui.*` requests (snapshot, tap, type, swipe, idle). The server hands each to SimlessRuntime (`simless_runtime_ui`), whose UI test automation then works on the render window only, plus menus and alerts above it. The render window is in the app's scene, or has none on a Mac with no login session, and in both a text field in it still becomes first responder and takes typed text. A final `tree` request reads the canvas as it is, without mounting it again.

Renders take ~20–60 ms. The CLI turns the tree into compact text and runs deterministic checks:
- controls without labels,
- text exposed twice,
- elements cut off at the screen's side edges, or of zero size (content wholly below the fold is scroll content, reported as a count, not an issue),
- tap targets under 44 pt (configurable with `checks.minTapTarget`, and UIKit's own bar buttons are skipped),
- overlapping controls.

`checks.ignore` in `.simless.json` drops issues containing a given string. A split view's column resize handle (an unlabeled, full-height adjustable element, partly off screen when the sidebar is hidden) is left out of the tree.

## Fixtures nobody wrote

`root` and one fixture per `#Preview` block (and `PreviewProvider`) are generated from source at `simless up` (`Previews.swift`), and compiled against the build like a hot-reload patch, while the slot gets ready. A `Preview` value can't give its view back (`ViewPreviewBody` isn't public), so simless doesn't read previews from the binary. Instead each file with previews gets a copy in which every preview is a function that registers its body, in place: the copy keeps its line numbers (compile errors point at the preview), the file's private sample data and helpers stay, and everything else is blanked and resolves to the app's own code. `@Previewable` state becomes a small view's state, as the macro does it, and a body that returns a view controller or a UIView is wrapped in a representable. `root` is the `@main` App rewritten as a view: its properties (`@StateObject`s, `@Environment`), its first `WindowGroup`'s content as the body, and the scene modifiers views have too (`.modelContainer`, `.environment`, `.environmentObject`). Its `init` doesn't run again, and a `@UIApplicationDelegateAdaptor` reads the app's delegate.

A preview that doesn't compile is left out with the compiler's reason, and the rest compile again without it, five rounds at most. simless leaves out an entry by its file and its name, so an error in one file never leaves out an entry of another. Names come from every entry that the scan finds in the app target, whether it compiles or not, so a name never changes when another entry starts or stops compiling. Entries in local packages are never generated and take no part. A name that one entry has stays as it was. `@main` Apps that share a name are each `<file name>.root` (`DemoApp.root`, `DemoWatchApp.root`). Previews in two or more files that share a name are each `<folder>.<name>`, the folder that holds the file (`Loadbudget.ContentView.1`, `LoadbudgetWatch.ContentView.1`). Previews in one file that share a name: the first keeps it, and the next are `<name>.2`, `<name>.3`. When two entries still share a name after that (one folder name and file name in two places, or a new name that another entry already has), `simless up` stops before it builds, with an error that names both paths relative to the worktree and says what to rename: a preview or a folder for previews, a file for Apps. A hot reload names the entries the same way, from every file that `up` read: a clash among entries it does not render does not stop it, and a name it asks for that the sources no longer give stops it with "run simless up". If the last round still fails, `simless up` says so with its first error, and `previews.json` keeps every reason and no dylib. The dylib is loaded after every host start, before the newest hot-reload patch. A patch replaces the host's fixture registry, so its entry registers the previews again. Those come from the build's code, so a hot reload treats previews like other fixtures: `reload --render <preview>` compiles that preview into the patch from its file, and previews the edit reaches but the patch doesn't render are reported as stale.

## Unit tests

`simless test` doesn't use xcodebuild to run tests. It keeps a test host: a copy of the slot app launched with `SimlessRuntime.dylib` inserted (`DYLD_INSERT_LIBRARIES`) and Xcode's macOS test frameworks on `DYLD_FRAMEWORK_PATH`. The runtime listens on the slot's port and loads test bundles on request with `dlopen`:
- app test targets from the slot app's `PlugIns`,
- local package test targets, built for iOS devices with the package's scheme (`xcodebuild build-for-testing` from the package directory), with the package's resource bundles copied in and the bundle signed, since a sandboxed app only loads signed code. They build in the app's build folder, for the app build's destination and with its settings, so the package modules the app build compiled are reused: a no-op instead of a second build of the whole package. When the app's scheme already builds a package test target, `simless up` marks that bundle current and builds nothing for it. One xcodebuild at a time uses a worktree's build folder (a per-worktree lock).

Swift Testing runs through its ABI entry point (`swt_abiv0_getEntryPoint`), with a filter, a skip list and a parallelization width, and streams events as JSON. XCTest runs its default suite with an observer. Both report back over the socket, and the CLI prints failures and crashes as they happen.

A host runs many targets in one process, so the app's startup is paid once per host, not once per target. Tests on the main actor run one at a time in a process, though, and heavy ones (rendering, image comparisons) would queue everything else behind them. So a big run uses several hosts (`--hosts`, by default up to 4 when there are 4 or more targets), each its own slot (`test`, `test2`, …). Targets are spread by their wall time in the last run, from the first test's start to the last one's end (the sum of test times says little when tests run side by side), longest first onto the least loaded host. A target that takes half again as long as any other gets a host to itself. The wall times are kept per repository in `~/Library/Application Support/Simless/history`, keyed by the origin remote, so they survive `simless clean` and a new worktree uses them too. When a run finishes, the next hosts are started in the background (with a token, so only a host simless started for this is reused), and they're usually up by the next run.

A test that crashes the host or runs past `--timeout` doesn't end the run:
- simless stops the slot's processes, reads the crash report and names the test. It waits for the report as a render does: 4 s, then up to 90 s when the host's log has no trap or frames. If the crashed thread's stack has one of the running tests on it, that test is blamed.
- a fresh host runs only what didn't finish.
- tests that were running when the host went down, and that the stack doesn't clear up, run again after the others, together. A group that brings its host down again is split in half until the crash lands on one test.
- a test that ran out of time, or one of a few failures (up to 30), is run alone. If it passes there, it's reported as flaky, not as passed or failed.

App test targets run in the slot app from the last full build, so a run must never use that build once a file it was built from has changed. `simless up` records every file under the project's folder and the local packages (size, modification time and content hash, build output and UI test sources aside) as of the build's start, and `simless test` compares before it runs: anything changed, added or removed, and it runs `simless up` first, or stops if that build fails. Only a run of package test targets after package edits alone goes straight on, since those build from current sources every run.

The exit code and the results files are meant for a merge check. The app's test targets come from the app scheme's `.xctestrun`, picked by the scheme's name, since package test builds in the same folder leave their own next to it. Every test the selection covers gets one status. One that nothing came back for is `not-run` and fails the run, and so does a selection that matches no test. Independently of the build, `simless test all` also checks every test target it had to cover (the app scheme's, from its testables and test plans, and every local package's): one with no test in the run is a `not-run` entry of its own. Tests that aren't expected to run here (simulator-only, `--skip`ped, or in a UI test target the scheme doesn't build) are listed with their own status and don't count against it.

Tests marked in `tests.simulatorOnly` (or skipped with a reason starting "simulator only") are counted apart, and `simless test --simulator-only` lists them with the xcodebuild command that runs them in a simulator: per target, the shared scheme that tests it and a simulator of its platform. The destination is a simulator named exactly like `calibrate.device` (an Apple Watch for watchOS) on `calibrate.runtime`, or the newest installed runtime. Anything else, such as another session's simulator, doesn't count: when the runtime or device is missing, simless says which and prints the `xcodebuild -downloadPlatform` or `xcrun simctl create` command, and exits 1.

Every run starts from a fresh install's data, like a simulator's clones. A host can't be emptied while it runs, so the app's data container is emptied right before each test host starts (the standby host for the next run included): the app is launched once with `SIMLESS_WIPE=1`, clears its preferences domains through `UserDefaults` (cfprefsd keeps them in memory, and its files are left to it) and deletes its other files, keeping the container's folders. Before a UI test quits the app, the app syncs its preferences, so what it saved is there on the next launch. That launch also shows whether macOS still opens the install, and a slot it won't open is installed again.

Test runs in different worktrees share the Mac. A run leaves a marker with its pid in its worktree's work folder, and a run that starts while others go takes its share of the cores (half with one other run): fewer hosts and fewer tests at once per host, so concurrent runs don't push each other into timeouts.

## UI tests

`simless test ui` (or a UI test target, class or test) runs the app's XCUITest code without a simulator. The test sources are compiled unchanged for macOS, as a test bundle, together with `SimlessXCUI.swift`. That file defines `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`, `XCUICoordinate`, `XCUIDevice` and the rest in the test module, so they take precedence over XCTest's. `xcrun xctest` runs the bundle.

The package products in the target's `packageProductDependencies` are linked into the bundle. Each comes from the local package the project file names for it, or, when it names none (as XcodeGen writes it), from the one package whose manifest declares it among the local packages (`packages` in `.simless.json`, else those of the project) and the packages they use by `.package(path:)`. `swift build --build-system swiftbuild --triple arm64-apple-macosx --product <product>` builds it for the Mac, in a scratch folder under the work folder. When the package, or a local package it uses, has remote dependencies, the build takes their versions from its `Package.resolved` alone (`--only-use-versions-from-resolved-file`), so it writes nothing into the package, and a package with no `Package.resolved` stops the run. That engine writes a `lib<product>.a` that holds the product's targets and the targets they depend on. The bundle gets the build folder as a module search path, the module map of each C target the products use (`-Xcc -fmodule-map-file=`), and the archives as link inputs. The linker takes from an archive only the members that the test code references, as with any static archive. So a package target whose code the tests never reference, such as one that only registers a conformance, is not linked, where Xcode links each product in full. Linking each archive in full (`-force_load`) is not an option: when two products share a target, both archives hold its object file, and the link fails with duplicate symbols. The bundle is built for macOS 14.0, or for the newest macOS that a linked package names in its `platforms`, since Swift refuses to import a module built for a newer macOS. A product of a remote package, one that no local package declares, one that two declare, or one whose build fails stops the run with an error that names the product and the target. The bundle is built again when a file of a linked package, or of a local package it uses by path, changes. Package code is compiled as macOS code: the rewrite of platform conditions below applies to the test sources only.

Each `XCUIApplication.launch()` starts a UI host, a copy of the slot app with the runtime inserted, the test's arguments and environment, and an iPhone-sized canvas. The host is hidden but runs the app's real startup (`SIMLESS_HEADLESS` isn't set). The test talks to the runtime over a socket:
- **Queries** run against a snapshot of the app's accessibility tree, with XCUITest's element types, identifiers, labels, values and frames.
- **Waits and snapshots** read that tree too. `waitForExistence`, `waitForNonExistence` and `wait(for:toEqual:timeout:)` fetch it again every 50 ms until the answer comes or the timeout ends. `snapshot()` fetches it once and gives the element and every node below it as an `XCUIElementSnapshot`, with `children` and `dictionaryRepresentation`. It throws when the element matches nothing or the app doesn't answer.
- **Screenshots** come from the app's window. `XCUIScreen.main`, the only entry of `XCUIScreen.screens`, and `XCUIApplication().screenshot()` give the same picture; an element's screenshot is the part of it inside the element's frame. Each is an `XCUIScreenshot` with `pngRepresentation` and an `NSImage` `image`, as Apple declares for macOS, because the bundle builds for macOS and has no `UIImage`.
- **Taps** on SwiftUI elements are accessibility activations when the element has an action. Everything else is a touch: a `UITouch` in a `UITouchesEvent` with a digitizer `IOHIDEvent`, sent through `-[UIApplication sendEvent:]`. SwiftUI's gestures live in gesture recognizer containers that aren't views, so for each touch the runtime asks the view under the finger for its container (`-[UIView _hitTestWithContext:]`) and adds that container's recognizers to the touch.
- **Drags and swipes** move at a finger's pace. UIKit measures part of a swipe's speed in real time, so a drag replayed faster carried too much momentum. A drag is a fixed list of small moves, each handled before the next. A swipe goes by the clock and eases off over its last fifth before the finger lifts, so the glide after it carries a list less than a screen, like a real flick.
- **Waiting:** after every action the runtime waits for animations that are on screen and moving, scroll views that are still gliding, and presentations and dismissals in flight, the way XCUITest waits for the app to settle. A glide's last points crawl for a second or more, so a scroll view moving under about 15 pt/s is stopped the way a landing finger stops it.
- **The tree is XCUITest's,** not VoiceOver's: below an element, the runtime also walks its `automationElements`, so a combined element's children keep their identifiers. Audits skip those, since they look at what VoiceOver reads.
- **What the Mac shows differently is emulated.** UIKit shows alerts as AppKit panels and menus as AppKit menus, outside the app's tree. The runtime intercepts them and puts iPhone-style alerts, action sheets and menus into the tree, with the identifiers the app gave their buttons, and submenus that open on a tap. The same goes for a text field's edit menu on a long press, the share sheet (a sheet with Close), compact date pickers (a button, then wheels), and the keyboard (keyboard notifications, an iPhone keyboard's frame and the input accessory bar).
- **No permission dialogs.** A host is a real Mac app, so a permission request (calendar, notifications, microphone, camera, speech, photos, contacts, location, tracking) or a review request would show macOS's own dialog on the user's screen. The runtime replaces those request methods and answers them: denied, or nothing for a review. `SIMLESS_PERMISSIONS=ask` lets them through. `resetAuthorizationStatus(for:)` changes nothing by default, since the runtime stores no answer between launches. Under `ask` it runs `tccutil reset <service> <slot bundle id>` for the resource's TCC service, and does nothing for location, health, a keyboard's network access and the local network, for which `tccutil` resets no service on macOS.
- **UI test sources are compiled as iOS code.** `#if os(macOS)`, `canImport(AppKit)`, `targetEnvironment(simulator)` and friends in the test sources are rewritten to the iPhone simulator's answers before compiling for the Mac, and test discovery uses the same answers.
- **Audits** (`performAccessibilityAudit`) are simless's own checks with the same audit types, since Xcode's audit runs in a system service.

Tests are spread over several hosts (`--jobs`) by their last durations. Each host is its own slot (`ui1`, `ui2`, …), because macOS runs one instance per bundle id. A failure saves a screenshot and the element tree next to the run's logs. `--device iphone,ipad` or `tests.uiDevices` run the suite (or a device's own list of tests) once per device and merge the results file, each test with its result per device. UI test targets the project has but the scheme doesn't build are found in the project file and listed, with their tests, as not built or simulator-only. A UI test target's sources are its synchronized folders and the files of its Sources build phase in the project file, where a file's path comes from the groups that hold it, plus the folder `tests.uiSources` names. When the target has no synchronized folder, lists no Swift file and has no `tests.uiSources`, the folder named like the target. Its tests are the `func test...()` methods with no result of each class whose chain of superclasses, declared in any of its files, reaches `XCTestCase`: at the top of the class's body, of `extension <Class>` blocks in any file, and in its superclasses, since XCTest runs inherited tests in each subclass. The scan skips comments and string literals and counts braces, so a method in a nested type is not a test. A base class with no such method yields no tests. A UI test source that no other target compiles is left out of the record of the app's build; a file the app compiles too stays in it.

## 4. Hot reload

`simless reload` compiles **only the edited files plus the fixtures file** into a patch dylib with its own module name:

```
@testable import App          // prepended to each edited file
...                           // the patch's copies of edited types shadow the app's
@_cdecl("simless_patch_entry") func entry(registry) { simlessFixtures(registry) }
```

- **Flags:** compiler flags are reconstructed from the target's build settings (Swift version, default isolation, upcoming features, conditions, deployment target), plus `-I/-F` to the build products and every Clang module map the app imports transitively. Undefined symbols resolve at load time against the app's debug dylib (`-undefined dynamic_lookup`).
- **Applying it:** the host `dlopen`s the patch and calls the entry point. That runs the patch's copy of the fixtures, so every fixture is rebuilt from the new view code. Typical cost is ~1.7 s compile + ~0.2 s apply.
- **Getting the patch into the host:**
  - **Live (default when available):** SimlessAgent copies the patch into the host's sandbox `tmp` directory, and the host loads it from there.
  - **Warm (no permissions):** the patch is bundled into the slot app, which is re-signed, reinstalled and relaunched, and the host loads it at startup. Takes ~10 s.
- **Scope:** a patch's copy of a type only takes effect where the patch itself constructs it, so an unedited parent would still embed the old subview. Before compiling, simless builds a graph of the app's sources and every local package module, by top-level declaration (a type and its extensions are one node), with edges from identifiers in code (not comments or strings). Across modules it only follows `public`/`open` types along declared package dependencies. The rules:
  - **What changed:** each edited file is compared declaration by declaration with its copy from the last full build (`simless up` keeps APFS clones of the sources it built), so an edit to one view's `body` changes that view only, not every type in its file.
  - **Views reach views:** from an edited view, only views that name it are affected, because they construct or embed it. A store, model or enum that names a view doesn't make a render stale: renders go from view to view. A "view" is anything that conforms to `View`, `ViewModifier`, a style or representable protocol (or an app protocol that refines one), a UIKit view or view controller class, or any declaration whose code builds views (`some View`, `AnyView`, `@ViewBuilder`).
  - **Logic reaches everything:** from an edited non-view type (a model, a view model), everything that names it is affected, views and non-views alike.
  - **Per fixture:** each fixture only needs the affected views on its own way to the edit. `reload --render X` patches what X needs (plus what the previous patch covered, when it fits). Other fixtures that reach the edit are listed as stale until the next full build, and `simless render` says so on each of them. They never trigger a rebuild.
  - **Only what's patched is compiled:** in each file the patch includes, declarations that aren't patched are blanked (lines and `#if`s kept, so errors still point at the right line) and resolve to the app's own copy. A second copy of an unchanged `extension View { func card() }` would be ambiguous next to the app's.
  - **Can't be traced:** edits that other code can observe without naming an edited type, which are extensions of types outside the sources and non-private top-level functions or variables, fall back to a full build. So do patches reaching more than 40 files.
  - The analysis over-approximates where it's unsure: an extra file costs compile time, a missing one costs a wrong render. `simless reload --dry-run` prints what a reload would patch and which fixtures would be stale.
- **Compiling it:** one frontend job per file (`-j`), so each loads the app's modules side by side, plus the header search paths of package C targets and static xcframeworks that the app build passes (`Products/include`, each generated module map's umbrella folder).
- **Package modules:** `simless init` records the local Swift packages the project references. Each source file is mapped to its module, and each module's language mode, default isolation and upcoming features are read from `swift package dump-package`. The patch `@testable import`s every module involved and compiles with their settings. A patch mixing modules with different settings can't be one module, so it falls back to a full build.
- **Fallback:** if a patch can't compile (stored properties, signatures, or a real error) or can't be scoped, reload falls back to a full build. Errors are mapped back to the user's `file:line`.
- **Which files count as edited:** content hashes against a snapshot taken when the build started. Git checkouts that only touch mtimes don't count.
- **After a failed build:** the host still runs the last build that worked, so a failed `up` puts back that build's snapshot (with the copies of its files) and leaves its previews' list, and only a build that works replaces them. A reload after a fixed compile error therefore diffs against the code the host runs. A fixture the reload is asked for but can't trace is stale, never covered. Each build records an id of its sources and each patch the id of the sources it compiled, and `--json` and `simless render` say when the host is behind the sources on disk.
- **Relaunches:** the newest patch is re-applied whenever the host relaunches.

## Calibration

`simless calibrate` builds the app for the iOS Simulator, boots one dedicated simulator and launches the app there with the same `--simless-port` argument. The same SimlessKit then serves renders from real iOS, with the device's own safe areas and traits. SimlessRuntime is not loaded in the simulator, so calibration needs the kit in the app, which `simless init` no longer writes, and without it `simless calibrate` stops with an error before it builds. For every fixture it renders on both, aligns the two accessibility trees by role, label and identifier (longest common subsequence), and reports elements present on only one side, and frames that differ by more than 2 pt. Each side reads its first frame, so a screen that loads its data in a `.task` compares its loading state; `--settle <ms>` (or `settle` in `.simless.json`) gives each side that time before it reads the screen. It's the only command that boots a simulator, and it deletes the device afterwards.

## 5. SimlessAgent and its security model (dfi mode)

The native mode doesn't use it: its hosts aren't sandboxed, so simless places patches itself. In the dfi mode, a file written by the sandboxed host is quarantined, and `dlopen` of quarantined code blocks on a Gatekeeper prompt, which would hang a headless host. Something outside the sandbox therefore has to place the patch in the host's container. Containers are protected ("App Data"), so that process needs **Full Disk Access**. SimlessAgent is that process: a tiny unsandboxed app (`ai.abacus.simless.agent`) listening on a Unix socket. It has exactly one write operation, `place`, and accepts it only when all of these hold:

- the source is a `.dylib` under `~/Library/Caches/simless/`, with no symlinks.
- the destination is `~/Library/Containers/<UUID>/Data/tmp/<file>.dylib`, with no symlinks on the path, and the write is atomic, so a planted symlink is replaced rather than followed.
- the container's `.com.apple.containermanagerd.metadata.plist` names a bundle id ending in `.simless<N>`.

Two further safeguards:
- **The host refuses to load anything quarantined.** It deletes each patch file after loading it.
- **The agent is optional.** Without it, or without Full Disk Access, reloads use warm mode.

## 6. Coordination and cleanup, without a daemon

Hosts and the agent are already long-lived processes, so the CLI coordinates with `flock`:

- **Locks:**
  - `state-<hash>`: a worktree's slot records, in `state.json` of its work folder (`~/Library/Caches/simless/work/<hash>-<name>/`), next to its slots in `slots/`,
  - `install`: one install machine-wide,
  - `build-<k>`: a few concurrent full builds,
  - `build-<worktree>`: one xcodebuild at a time in a worktree's build folder.
- **Garbage collection** runs on every command and removes hosts, slots, LaunchServices registrations and build caches of worktrees that no longer exist. It stops a worktree's hosts, then deletes its work folder.
- **Size limits:** only the newest 3 patches are kept per worktree, the shared Xcode compilation cache is cleared above 8 GB, and everything simless keeps stays under 25 GB (`SIMLESS_DISK_LIMIT_GB`). Over that, `simless up` removes the builds and slots of the least recently used worktrees, never one used in the last hour, then the shared compilation cache.
- **Unused worktrees** (no simless command for two weeks) lose their hosts, slots and builds, and crash reports of simless hosts go after a day.
- **`simless clean [--all]`** removes everything simless created.

## Limits

See [How far to trust results](../README.md#how-far-to-trust-results) for what a pass and a failure mean, the known ways a pass can be wrong (hot reload with nested views, device traits, safe areas, Dynamic Type), and how unit tests can differ. In brief:

- **Hot reload replaces only the edited types.** It also patches the views on the way from the rendered fixtures to the edit. Other fixtures that reach the edit run the previously built code until the next full build, and are reported as stale.
- **Traits aren't an iPhone's.** It's an iOS app on a Mac: the idiom is `.pad` unless `--idiom phone` is passed (then the trait collection and `UIDevice.current.userInterfaceIdiom` both report `.phone`). simless sets phone size classes and safe areas itself, and its runtime makes text scale with Dynamic Type.
- **No capabilities.** Slots run without app capabilities. App-group containers are private folders.
- **Not covered:** system UI that UI tests don't emulate (HealthKit and StoreKit sheets, photo and file pickers, the Home Screen), features that need a permission (it's denied), the watch app, and pixel-exact rendering.
- **The Mac's Swift runtime:** tests run against the Mac's system libraries, not the simulator's. Plain CPU work runs at the simulator's speed, but unoptimized generic code can be slower.
- **Project shape:** needs an `.xcodeproj` (at the root or in a subfolder) with an app-hosted unit-test target.
- **Side effects:** the host runs the app's real startup. Render hosts get no network through URL Loading, but WKWebView, raw sockets and other side effects need a guard: a render host has `--simless-port` in its arguments.
- **Private APIs:** the hosts use private Apple APIs, compiled only into simless builds, (`_AXSSetAutomationEnabled`, NSApplication activation policy via the ObjC runtime, `sandbox_extension_consume`, CoreText's text-style tables, UIKit's touch and gesture-container internals) that an OS update could change.
