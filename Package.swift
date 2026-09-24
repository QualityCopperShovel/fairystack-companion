// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FairyStackCompanion", platforms: [.macOS(.v13)], products: [
    .executable(name: "FairyStackCompanion", targets: ["FairyStackCompanion"])
], targets: [
    .target(name: "CommandRunner", publicHeadersPath: "include"),
    .target(name: "WorkspaceWindow"),
    .executableTarget(name: "FairyStackCompanion", dependencies: ["CommandRunner", "WorkspaceWindow"]),
    .testTarget(name: "WorkspaceWindowTests", dependencies: ["WorkspaceWindow"])
])
