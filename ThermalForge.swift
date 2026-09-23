import Foundation

/// What `thermalforge status` prints: every fan plus every temperature sensor it found.
struct ThermalStatus: Decodable {
    struct Fan: Decodable {
        let index: Int
        let actualRpm: Int
        let targetRpm: Int
        let minRpm: Int
        let maxRpm: Int
        let mode: String
    }

    let fans: [Fan]
    let temperatures: [String: Double]

    // Same sensor families ThermalForge's own safety check watches.
    var cpu: Double? { peak(["TC", "Tp"]) }
    var gpu: Double? { peak(["TG", "Tg"]) }

    private func peak(_ prefixes: [String]) -> Double? {
        temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }.values.max()
    }
}

struct ThermalForgeError: LocalizedError {
    let errorDescription: String?
}

/// Runs the ThermalForge CLI. Calls block, so run them off the main thread.
enum ThermalForge {
    private static let cliPaths = ["/opt/homebrew/bin/thermalforge", "/usr/local/bin/thermalforge"]

    private static var cli: String? {
        // THERMALFORGE_PATH points the app at a stand-in CLI for testing.
        if let override = ProcessInfo.processInfo.environment["THERMALFORGE_PATH"] { return override }
        return cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> Data {
        guard let cli else {
            throw ThermalForgeError(errorDescription: "Install ThermalForge first. See README.md in this project.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ThermalForgeError(errorDescription: message?.isEmpty == false ? message : "thermalforge \(arguments.joined(separator: " ")) failed")
        }
        return data
    }

    static func status() throws -> ThermalStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ThermalStatus.self, from: run(["status"]))
    }
}
