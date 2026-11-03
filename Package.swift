// swift-tools-version: 6.0

import PackageDescription

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
        // The macOS app: SwiftUI shell, AppKit session views and the RDPKit backend.
        .executableTarget(
            name: "RDPManager",
            dependencies: [
                "RDPManagerCore",
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
