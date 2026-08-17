// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacScannerX",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacScannerX", targets: ["MacScannerX"])
    ],
    targets: [
        .target(
            name: "CHPUSB",
            path: "Sources/CHPUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "MacScannerX",
            dependencies: ["CHPUSB"],
            path: "Sources/MacScannerX",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
