// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VueScanX",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VueScanX", targets: ["VueScanX"])
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
            name: "VueScanX",
            dependencies: ["CHPUSB"],
            path: "Sources/VueScanX",
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
