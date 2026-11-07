// swift-tools-version:5.9
import Foundation
import PackageDescription

/// AppIntents metadata (the widget's configuration) is produced by Xcode's
/// appintentsmetadataprocessor from the compiler's constant values. Xcode
/// asks the compiler for them itself; here we do it with flags. See make-app.sh.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Stockmote",
    platforms: [.macOS(.v14)],
    targets: [
        // Treemap, colours, Yahoo client and the file the app shares with the widget.
        .target(
            name: "StockmoteShared",
            path: "Sources/StockmoteShared"
        ),
        .executableTarget(
            name: "Stockmote",
            dependencies: ["StockmoteShared"],
            path: "Sources/Stockmote",
            resources: [.copy("Resources/Indices.json")]
        ),
        // The widget extension. SwiftPM builds the binary; Scripts/make-app.sh
        // packages it as Stockmote.app/Contents/PlugIns/StockmoteWidget.appex.
        .executableTarget(
            name: "StockmoteWidget",
            dependencies: ["StockmoteShared"],
            path: "Sources/StockmoteWidget",
            swiftSettings: [
                .unsafeFlags([
                    "-emit-const-values-path", "\(root)/.build/StockmoteWidget.swiftconstvalues",
                    "-Xfrontend", "-const-gather-protocols-file",
                    "-Xfrontend", "\(root)/Scripts/appintents/protocols.json"
                ])
            ],
            linkerSettings: [
                // Extensions must start in Foundation's _NSExtensionMain, not in
                // main — otherwise the process dies in ExtensionFoundation before
                // WidgetKit gets going. Xcode does this for appex targets; SwiftPM
                // doesn't know this is an extension.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        )
    ]
)
