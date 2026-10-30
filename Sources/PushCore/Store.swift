import Foundation

/// Files under ~/Library/Application Support/Pushwright. The app writes them; the CLI only reads.
public enum Store {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pushwright", directoryHint: .isDirectory)
    }

    public static var socketPath: String { directory.appending(path: "pushwright.sock").path(percentEncoded: false) }
    static var profilesURL: URL { directory.appending(path: "profiles.json") }
    static var targetsURL: URL { directory.appending(path: "targets.json") }
    static var historyURL: URL { directory.appending(path: "history.jsonl") }
    static let historyLimit = 20_000_000
    static let historyLock = NSLock()

    public static func loadProfiles() throws -> [Profile] { try load(profilesURL) ?? [] }
    public static func saveProfiles(_ profiles: [Profile]) throws { try save(profiles, to: profilesURL) }
    public static func loadTargets() throws -> [Target] { try load(targetsURL) ?? [] }
    public static func saveTargets(_ targets: [Target]) throws { try save(targets, to: targetsURL) }

    public static func appendHistory(_ record: SendRecord) throws {
        historyLock.lock()
        defer { historyLock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // ponytail: keeps one rotated file and drops anything older; add more generations if anyone needs them.
        if let size = try? historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > historyLimit {
            let old = directory.appending(path: "history.1.jsonl")
            try? fm.removeItem(at: old)
            try fm.moveItem(at: historyURL, to: old)
        }
        if !fm.fileExists(atPath: historyURL.path(percentEncoded: false)) {
            fm.createFile(atPath: historyURL.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: historyURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSON.encode(record) + Data("\n".utf8))
    }

    /// Newest last.
    public static func history(last count: Int) -> [SendRecord] {
        Array(allHistory().suffix(count))
    }

    /// The most recent accepted APNs push to this token, used to remember its environment.
    public static func lastSuccess(tokenHash: String) -> SendRecord? {
        allHistory().last { $0.ok && $0.via == .apns && $0.tokenHash == tokenHash }
    }

    // ponytail: reads the whole file (≤20 MB) on each lookup; index it if history gets slow.
    static func allHistory() -> [SendRecord] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSON.decode(SendRecord.self, from: Data($0.utf8)) }
    }

    static func load<T: Decodable>(_ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSON.decode(T.self, from: Data(contentsOf: url))
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSON.encode(value, pretty: true).write(to: url, options: .atomic)
    }
}
