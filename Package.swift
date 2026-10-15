// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScriptVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScriptVoice",
            path: "Sources/ScriptVoice"
        )
    ]
)
