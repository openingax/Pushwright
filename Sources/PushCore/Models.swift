import CryptoKit
import Foundation

public enum PushCore {
    public static let version = "0.1.0"
    public static let appBundleId = "com.openingax.pushwright"
}

public enum PushEnvironment: String, Codable, Sendable, CaseIterable {
    case sandbox, production

    public var host: String {
        self == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }
}

public enum PushType: String, Codable, Sendable, CaseIterable {
    case alert, background, voip, liveactivity, widgets, controls
    case location, pushtotalk, fileprovider, complication, accessory

    /// Appended to the bundle ID to form `apns-topic`.
    public var topicSuffix: String {
        switch self {
        case .alert, .background: ""
        case .voip: ".voip"
        case .liveactivity: ".push-type.liveactivity"
        case .widgets: ".push-type.widgets"
        case .controls: ".push-type.controls"
        case .location: ".location-query"
        case .pushtotalk: ".voip-ptt"
        case .fileprovider: ".pushkit.fileprovider"
        case .complication: ".complication"
        case .accessory: ".push-type.accessory"
        }
    }

    public var maxPayloadBytes: Int { self == .voip ? 5120 : 4096 }
    public var defaultPriority: Int { self == .background ? 5 : 10 }
    /// `simctl push` only delivers regular app pushes.
    public var simctlSupported: Bool { self == .alert || self == .background }
}

public enum Via: String, Codable, Sendable {
    case apns, simctl
}

/// Sending credentials. Only metadata lives here; the .p8 key sits in the Keychain.
public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case token, certificate }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var teamId: String?
    public var keyId: String?
    public var certificateSHA256: String?
    public var certificateName: String?
    /// Default topic base when the target has no bundle ID.
    public var bundleId: String?
    /// Environments this key or certificate may send to.
    public var environments: [PushEnvironment]

    public init(
        id: UUID = UUID(), name: String, kind: Kind, teamId: String? = nil, keyId: String? = nil,
        certificateSHA256: String? = nil, certificateName: String? = nil, bundleId: String? = nil,
        environments: [PushEnvironment]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.teamId = teamId
        self.keyId = keyId
        self.certificateSHA256 = certificateSHA256
        self.certificateName = certificateName
        self.bundleId = bundleId
        self.environments = environments
    }
}

/// A device token added by hand. Simulators are found live through simctl.
public struct Target: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var alias: String
    public var token: String
    public var environment: PushEnvironment
    public var bundleId: String?

    public init(id: UUID = UUID(), alias: String, token: String, environment: PushEnvironment, bundleId: String? = nil) {
        self.id = id
        self.alias = alias
        self.token = token
        self.environment = environment
        self.bundleId = bundleId
    }
}

/// One line of history.jsonl.
public struct SendRecord: Codable, Sendable {
    public var sendId: String
    public var at: Date
    public var via: Via
    public var target: String
    public var tokenTail: String?
    public var tokenHash: String?
    public var environment: PushEnvironment?
    public var profile: String?
    public var pushType: PushType
    public var topic: String?
    public var priority: Int?
    public var bytes: Int
    public var status: Int?
    public var apnsId: String?
    public var uniqueId: String?
    public var reason: String?
    public var ok: Bool
}

public enum DeviceToken {
    /// Accepts tokens copied from logs, e.g. `<ab12 cd34 ...>`.
    public static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { !"<> \n\t".contains($0) }
    }

    public static func isValid(_ token: String) -> Bool {
        !token.isEmpty && token.count.isMultiple(of: 2) && token.allSatisfy(\.isHexDigit)
    }

    public static func tail(_ token: String) -> String { "…" + token.suffix(6) }

    /// Lets history match a token without storing it in full.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ExitStatus {
    public static let ok: Int32 = 0
    public static let apns: Int32 = 1
    public static let lint: Int32 = 2
    public static let expectation: Int32 = 3
    public static let approval: Int32 = 4
    public static let config: Int32 = 5
    public static let usage: Int32 = 64
}

/// The error shape every command reports, in JSON and as the exit code.
public struct ErrorInfo: Codable, Sendable, Error {
    public var code: String
    public var message: String
    public var status: Int?
    public var reason: String?
    public var cause: String?
    public var fix: String?
    public var retryable: Bool?
    public var exitCode: Int32

    public init(
        code: String, message: String, status: Int? = nil, reason: String? = nil, cause: String? = nil,
        fix: String? = nil, retryable: Bool? = nil, exitCode: Int32
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.reason = reason
        self.cause = cause
        self.fix = fix
        self.retryable = retryable
        self.exitCode = exitCode
    }

    static func config(_ code: String, _ message: String) -> ErrorInfo {
        ErrorInfo(code: code, message: message, exitCode: ExitStatus.config)
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
