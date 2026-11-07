// swift-tools-version:5.9
import Foundation
import PackageDescription

/// AppIntents-metadata (widget'ens konfiguration) laves af Xcodes
/// appintentsmetadataprocessor ud fra compilerens konstantværdier. Xcode
/// beder selv compileren om dem; her gør vi det med flag. Se make-app.sh.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Stockmote",
    platforms: [.macOS(.v14)],
    targets: [
        // Treemap, farver, Yahoo-klient og den fil appen deler med widget'en.
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
        // Widget-udvidelsen. SwiftPM bygger binæren; Scripts/make-app.sh
        // pakker den som Stockmote.app/Contents/PlugIns/StockmoteWidget.appex.
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
                // Udvidelser skal starte i Foundations _NSExtensionMain, ikke
                // i main — ellers dør processen i ExtensionFoundation før
                // WidgetKit når at starte. Det er det Xcode gør for appex-
                // targets; SwiftPM ved ikke at det er en udvidelse.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        )
    ]
)
