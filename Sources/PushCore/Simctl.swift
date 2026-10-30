import Foundation

public struct BootedSimulator: Codable, Sendable, Hashable {
    public var udid: String
    public var name: String
    public var runtime: String
}

public enum Simctl {
    public static func booted() -> [BootedSimulator] {
        guard let result = try? run(["simctl", "list", "devices", "booted", "-j"]), result.status == 0,
              let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return devices.flatMap { runtime, list in
            list.compactMap { device -> BootedSimulator? in
                guard device["state"] as? String == "Booted", let udid = device["udid"] as? String,
                      let name = device["name"] as? String else { return nil }
                // com.apple.CoreSimulator.SimRuntime.iOS-26-0 -> iOS-26-0
                return BootedSimulator(udid: udid, name: name, runtime: runtime.components(separatedBy: ".").last ?? runtime)
            }
        }
        .sorted { $0.name < $1.name }
    }

    public static func push(udid: String, bundleId: String, payload: Data) throws -> (status: Int32, output: String) {
        let result = try run(["simctl", "push", udid, bundleId, "-"], stdin: payload)
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        return (result.status, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func isAvailable() -> Bool {
        (try? run(["simctl", "help"]).status) == 0
    }

    static func run(_ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
}
