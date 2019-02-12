// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "crypto-kit",
    products: [
        .library(name: "CryptoKit", targets: ["CryptoKit"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "CBase32"),
        .target(name: "CBcrypt"),
        .systemLibrary(
            name: "CCryptoOpenSSL",
            pkgConfig: "openssl",
            providers: [
                .apt(["openssl libssl-dev"]),
                .brew(["libressl"])
            ]
        ),
        .target(name: "CryptoKit", dependencies: [
            "CBase32",
            "CBcrypt",
            "CCryptoOpenSSL"
        ]),
        .testTarget(name: "CryptoKitTests", dependencies: ["CryptoKit"]),
    ]
)
