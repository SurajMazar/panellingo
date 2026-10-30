// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PanelLingo",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PanelLingoKit", targets: ["PanelLingoKit"]),
        .executable(name: "PanelLingo", targets: ["PanelLingo"]),
        .executable(name: "panellingo-cli", targets: ["panellingo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "PanelLingoKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PanelLingo",
            dependencies: ["PanelLingoKit"],
            exclude: ["Resources/Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "panellingo-cli",
            dependencies: ["PanelLingoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PanelLingoKitTests",
            dependencies: ["PanelLingoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
