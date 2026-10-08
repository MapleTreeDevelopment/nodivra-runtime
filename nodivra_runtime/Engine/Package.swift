// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NodivraEngine", products: [.executable(name: "NodivraEngine", targets: ["NodivraEngine"])], dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.9.1")], targets: [.target(name: "NodivraCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]), .executableTarget(name: "NodivraEngine", dependencies: ["NodivraCore"])])
