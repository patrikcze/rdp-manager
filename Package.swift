// swift-tools-version: 6.0

import PackageDescription

// FreeRDP 3 libraries built by Scripts/build-freerdp.sh (not checked in).
let freeRDP = Context.packageDirectory + "/ThirdParty/freerdp"

let package = Package(
    name: "RDPManager",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "RDPManager", targets: ["RDPManager"]),
        .executable(name: "RDPManagerAskpass", targets: ["RDPManagerAskpass"]),
    ],
    dependencies: [
        // Pinned exactly: the RDP engine is security-critical and its API still moves
        // between minor versions. See RDP-BACKEND-DECISION.md before bumping.
        .package(url: "https://github.com/steelbrain/RDPKit.git", exact: "0.7.0"),
        // The terminal emulator of SSH sessions (MIT). Pinned exactly: it parses everything a
        // server sends. See docs/SSH-IMPLEMENTATION-PLAN.md before bumping.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2"),
    ],
    targets: [
        // Models, persistence, credentials, parsing and session policy. No RDP engine, no UI.
        .target(
            name: "RDPManagerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A small C API over FreeRDP 3: the second engine, for Kerberos, Standard RDP Security
        // and device redirection (printers, smart cards, USB).
        .target(
            name: "FreeRDPBridge",
            cSettings: [
                .headerSearchPath("../../ThirdParty/freerdp/include/freerdp3"),
                .headerSearchPath("../../ThirdParty/freerdp/include/winpr3"),
                .unsafeFlags(["-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .linkedLibrary("freerdp3"),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("winpr3"),
                .unsafeFlags(["-L\(freeRDP)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(freeRDP)/lib",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // The macOS app: SwiftUI shell, AppKit session views, the RDPKit and FreeRDP backends
        // and the SSH terminal (system OpenSSH on a PTY, rendered by SwiftTerm).
        .executableTarget(
            name: "RDPManager",
            dependencies: [
                "RDPManagerCore",
                "FreeRDPBridge",
                .product(name: "RDPKit", package: "RDPKit"),
                .product(name: "RDPKitAppKit", package: "RDPKit"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // OpenSSH's askpass helper: relays a prompt to the app over the session's socket and
        // prints the answer. Bundled next to the app's executable.
        .executableTarget(
            name: "RDPManagerAskpass",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RDPManagerCoreTests",
            dependencies: ["RDPManagerCore"]
        ),
        // Runs the real RDPKit engine against local sockets and checks how the app reads it.
        .testTarget(
            name: "RDPEngineIntegrationTests",
            dependencies: [
                "RDPManager",
                "RDPManagerCore",
                "RDPManagerAskpass",
                "FreeRDPBridge",
                .product(name: "RDPKit", package: "RDPKit"),
            ]
        ),
    ]
)
