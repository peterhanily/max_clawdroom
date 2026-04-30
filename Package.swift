// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "max_clawdroom",
    // Default development locale for the Localizable.xcstrings catalog.
    // SPM requires this whenever .lproj resources ship — without it the
    // build fails with "manifest property 'defaultLocalization' not set".
    // The catalog declares `sourceLanguage: "en"`; this matches.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // User-visible binary name. The target stays as `Companion`
        // internally so source paths and module name don't churn.
        .executable(name: "max_clawdroom", targets: ["Companion"])
    ],
    dependencies: [
        .package(url: "https://github.com/magicien/GLTFSceneKit.git", from: "0.4.0"),
        // Auto-updates. Appcast URL + EdDSA public key live in
        // Packaging/Info.plist; release flow signs each DMG with
        // Sparkle's sign_update CLI and publishes the appcast.
        // See RELEASE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        // C-only library that ships a dyld __interpose record
        // overriding `swift_task_isCurrentExecutorWithFlagsImpl`.
        // See `Sources/CompanionRuntimePatch/Interpose.c` for the
        // full diagnosis; in short, the macOS 26.x implementation of
        // that runtime function corrupts a vtable lookup under heap
        // pressure and crashes any caller. We replace it with a
        // const-true stub. The interpose binds across every dylib
        // including SwiftUI, AppKit gesture recognizers, and the
        // Swift concurrency library itself.
        .target(
            name: "CompanionRuntimePatch",
            path: "Sources/CompanionRuntimePatch",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Companion",
            dependencies: [
                "GLTFSceneKit",
                "CompanionRuntimePatch",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Companion",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                // Swift 6.2 Approachable Concurrency. `defaultIsolation`
                // makes every type/function implicitly @MainActor unless
                // explicitly opted out with `nonisolated`. This app is
                // already ~98% MainActor, so making it the default
                // removes explicit annotations AND catches any accidental
                // main-actor-expected call from a background context at
                // compile time.
                //
                // Full Swift 6 strict-concurrency adoption: `ClaudeCodeProcess`
                // is `nonisolated final class ... @unchecked Sendable` with
                // lock-protected stdout/stderr buffers (reads off the
                // subprocess pipe stay off-main). `MenuItem` (NSMenuItem
                // subclass) is `nonisolated` with `MainActor.assumeIsolated`
                // in `@objc fire()`. Classes that touch MainActor state in
                // their teardown use SE-0371 `isolated deinit` (enabled via
                // Swift 6 language mode below).
                .defaultIsolation(MainActor.self),
                // **macOS 26.x runtime bug workaround.**
                // swift_task_isCurrentExecutorWithFlagsImpl — the
                // dynamic actor-isolation check Swift 6 injects at the
                // prologue of every @MainActor-isolated function /
                // closure — has a runtime bug on macOS 26.x that
                // intermittently dereferences corrupted state
                // (KERN_PROTECTION_FAILURE / NULL deref / objc_fatal,
                // depending on heap layout). Surfaced repeatedly across
                // VoiceHotkey, ShoutHotkey, MouseTracker, NSTimer
                // publishers, NSWindow subclass overrides, and SwiftUI
                // body closures during a single dev session.
                //
                // -disable-dynamic-actor-isolation (SE-0420) tells the
                // compiler to skip emitting those runtime checks. We
                // keep all Swift 6 STATIC concurrency enforcement (the
                // compile-time isolation checks, isolated deinit,
                // defaultIsolation). What we lose is the runtime sanity
                // check that an @MainActor function is actually being
                // called from MainActor — fine in practice, because
                // the static checks already prove this for pure-Swift
                // call sites, and AppKit / SwiftUI guarantee main-thread
                // invocation for the @objc bridge sites where the bug
                // surfaces.
                //
                // Revert this flag once Apple ships the runtime fix.
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
            ]
        ),
        .testTarget(
            name: "CompanionTests",
            dependencies: ["Companion"],
            path: "Tests/CompanionTests",
            swiftSettings: [
                // No defaultIsolation on tests — XCTestCase's
                // init/initWithSelector: are inherited from a
                // nonisolated Obj-C base class, so making the
                // subclass @MainActor by default fails the override
                // check. Tests opt into MainActor explicitly via
                // @MainActor on the test class when they need it.
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
