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
    ],
    dependencies: [
        // Pinned exactly: the RDP engine is security-critical and its API still moves
        // between minor versions. See RDP-BACKEND-DECISION.md before bumping.
        .package(url: "https://github.com/steelbrain/RDPKit.git", exact: "0.7.0"),
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
        // The macOS app: SwiftUI shell, AppKit session views and the RDPKit and FreeRDP backends.
        .executableTarget(
            name: "RDPManager",
            dependencies: [
                "RDPManagerCore",
                "FreeRDPBridge",
                .product(name: "RDPKit", package: "RDPKit"),
                .product(name: "RDPKitAppKit", package: "RDPKit"),
            ],
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
                .product(name: "RDPKit", package: "RDPKit"),
            ]
        ),
    ]
)
