// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Bu makinede Xcode yok; swift-testing'in macro plugin'i CLT içinde
// `plugins/testing/` alt dizininde durur ve SwiftPM onu kendiliğinden
// yüklemez. Varsa elle ekleniyor — yoksa (ör. Xcode kurulursa) bayrak
// eklenmez ve normal keşif yolu çalışır.
private let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? "/Library/Developer/CommandLineTools"

private func testingMacroFlags() -> [SwiftSetting] {
    let pluginPath = developerDirectory
        + "/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

    guard FileManager.default.fileExists(atPath: pluginPath) else { return [] }
    return [.unsafeFlags(["-load-plugin-library", pluginPath])]
}

// Testing.framework CLT'nin Frameworks dizininde durur ve test paketine
// gömülmez. SIP `DYLD_FRAMEWORK_PATH`'i sıyırdığı için yol link zamanında
// rpath olarak gömülür.
private func testingRunpathFlags() -> [LinkerSetting] {
    let frameworksPath = developerDirectory + "/Library/Developer/Frameworks"
    // Testing.framework ayrıca lib_TestingInterop.dylib'e bağlıdır; o da
    // ayrı bir dizinde durur, ikisi de rpath'e eklenir.
    let interopPath = developerDirectory + "/Library/Developer/usr/lib"

    guard FileManager.default.fileExists(atPath: frameworksPath + "/Testing.framework") else {
        return []
    }

    var flags = ["-Xlinker", "-rpath", "-Xlinker", frameworksPath]
    if FileManager.default.fileExists(atPath: interopPath + "/lib_TestingInterop.dylib") {
        flags += ["-Xlinker", "-rpath", "-Xlinker", interopPath]
    }
    return [.unsafeFlags(flags)]
}

let package = Package(
    name: "ATAK",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATAK", targets: ["ATAK"]),
        .library(name: "ATAKCore", targets: ["ATAKCore"]),
    ],
    targets: [
        // Tüm uygulama mantığı burada yaşar; test edilebilir olması için kütüphane.
        .target(
            name: "ATAKCore",
            path: "Sources/ATAKCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // İnce çalıştırılabilir kabuk: yalnız main.swift.
        .executableTarget(
            name: "ATAK",
            dependencies: ["ATAKCore"],
            path: "Sources/ATAK",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ATAKTests",
            dependencies: ["ATAKCore"],
            path: "Tests/ATAKTests",
            swiftSettings: [.swiftLanguageMode(.v6)] + testingMacroFlags(),
            linkerSettings: testingRunpathFlags()
        ),
    ]
)
