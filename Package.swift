// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SlideScroll",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "slidescroll", targets: ["SlideScroll"]),
        .executable(name: "core-checks", targets: ["CoreChecks"]),
    ],
    targets: [
        // Platform-independent model of the strip, unit-tested.
        .target(name: "SlideScrollCore"),
        .executableTarget(
            name: "SlideScroll",
            dependencies: ["SlideScrollCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "CoreChecks", dependencies: ["SlideScrollCore"]),
    ]
)
