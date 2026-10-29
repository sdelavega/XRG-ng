// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "XRGSharedCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "XRGSharedCore", type: .dynamic, targets: ["XRGSharedCore"])],
    targets: [
        .target(name: "XRGSharedCore", path: "Shared", exclude: ["Tests", "include"],
                sources: ["Sources", "Bridge"]),
        .testTarget(name: "XRGSharedCoreTests", dependencies: ["XRGSharedCore"], path: "Shared/Tests",
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
