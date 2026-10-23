// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IDeviceBinary",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "IDevice", targets: ["IDevice"])
    ],
    targets: [
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip",
            checksum: "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
        )
    ]
)
