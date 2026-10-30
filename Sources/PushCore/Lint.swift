import Foundation

public struct LintIssue: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable { case error, warn }

    public var rule: String
    public var level: Level
    public var message: String
}

/// What is known about the request besides the payload. Every field is optional.
public struct LintContext: Sendable {
    public var pushType: PushType?
    public var topic: String?
    public var priority: Int?
    public var collapseId: String?
    public var deviceToken: String?
    public var environment: PushEnvironment?
    /// The environment this token is known to belong to (target setting or past success).
    public var knownEnvironment: PushEnvironment?
    /// Environments the profile's key or certificate may use.
    public var allowedEnvironments: [PushEnvironment]?

    public init(
        pushType: PushType? = nil, topic: String? = nil, priority: Int? = nil, collapseId: String? = nil,
        deviceToken: String? = nil, environment: PushEnvironment? = nil,
        knownEnvironment: PushEnvironment? = nil, allowedEnvironments: [PushEnvironment]? = nil
    ) {
        self.pushType = pushType
        self.topic = topic
        self.priority = priority
        self.collapseId = collapseId
        self.deviceToken = deviceToken
        self.environment = environment
        self.knownEnvironment = knownEnvironment
        self.allowedEnvironments = allowedEnvironments
    }
}

/// Pre-send checks. Rule numbers are stable so agents can act on them (see docs/DESIGN.md §7.1).
public enum Lint {
    /// Reserved for receipt tracing (M3).
    public static let reservedKey = "pushwright"
    static let knownSuffixes = PushType.allCases.map(\.topicSuffix).filter { !$0.isEmpty }
    static let interruptionLevels: Set = ["passive", "active", "time-sensitive", "critical"]

    public static func inferType(_ payload: Data) -> PushType {
        parse(payload).map(inferType(json:)) ?? .alert
    }

    static func inferType(json: [String: Any]) -> PushType {
        guard let aps = json["aps"] as? [String: Any] else { return .alert }
        if aps["event"] != nil || aps["content-state"] != nil { return .liveactivity }
        if aps["alert"] != nil || aps["sound"] != nil || aps["badge"] != nil { return .alert }
        if int(aps["content-available"]) == 1 { return .background }
        return .alert
    }

    /// Returns the push type used for the checks (given or inferred) and the issues found.
    public static func check(_ payload: Data, _ context: LintContext = LintContext()) -> (pushType: PushType, issues: [LintIssue]) {
        var issues: [LintIssue] = []
        func error(_ rule: String, _ message: String) { issues.append(LintIssue(rule: rule, level: .error, message: message)) }
        func warn(_ rule: String, _ message: String) { issues.append(LintIssue(rule: rule, level: .warn, message: message)) }

        guard let json = parse(payload) else {
            error("L01", "Payload is not a JSON object.")
            return (context.pushType ?? .alert, issues)
        }
        guard let aps = json["aps"] as? [String: Any] else {
            error("L01", "Payload has no \"aps\" dictionary.")
            return (context.pushType ?? .alert, issues)
        }
        let type = context.pushType ?? inferType(json: json)
        let priority = context.priority ?? type.defaultPriority

        let limit = type.maxPayloadBytes
        if payload.count > limit {
            let (field, size) = largestField(json)
            error("L02", "Payload is \(payload.count) bytes, \(payload.count - limit) over the \(limit)-byte limit for \(type.rawValue). Largest field: \(field) (\(size) bytes).")
        }

        if let topic = context.topic {
            let suffix = type.topicSuffix
            if suffix.isEmpty, let other = knownSuffixes.first(where: { topic.hasSuffix($0) }) {
                error("L03", "Topic \(topic) ends with \(other), which does not match push type \(type.rawValue).")
            } else if !suffix.isEmpty, !topic.hasSuffix(suffix) {
                error("L03", "Push type \(type.rawValue) needs a topic ending in \(suffix); got \(topic).")
            }
        }

        if type == .background {
            if priority != 5 { error("L04", "Background pushes must use priority 5 (got \(priority)).") }
            let visible = ["alert", "sound", "badge"].filter { aps[$0] != nil }
            if !visible.isEmpty { error("L04", "Background pushes must not contain aps.\(visible.joined(separator: ", aps.")).") }
        }

        if type == .liveactivity {
            let missing = ["timestamp", "event"].filter { aps[$0] == nil }
            if !missing.isEmpty { error("L05", "Live Activity payload is missing aps.\(missing.joined(separator: ", aps.")).") }
            let event = aps["event"] as? String
            if let event, !["start", "update", "end"].contains(event) {
                error("L05", "aps.event must be start, update or end (got \(event)).")
            }
            if event == "start" || event == "update", aps["content-state"] == nil {
                error("L05", "aps.content-state is required for event \(event ?? "").")
            }
            if event == "start" {
                let missingStart = ["attributes-type", "attributes"].filter { aps[$0] == nil }
                if !missingStart.isEmpty { error("L05", "Starting a Live Activity needs aps.\(missingStart.joined(separator: ", aps.")).") }
            }
        }

        if let timestamp = aps["timestamp"] as? Double, timestamp >= 1e11 {
            warn("L06", "aps.timestamp looks like milliseconds; APNs expects seconds.")
        }

        if int(aps["mutable-content"]) == 1, aps["alert"] == nil {
            warn("L07", "mutable-content is set but there is no alert, so the notification service extension will not run.")
        }

        if let collapseId = context.collapseId, collapseId.utf8.count > 64 {
            error("L08", "apns-collapse-id is \(collapseId.utf8.count) bytes; the limit is 64.")
        }
        if let badge = aps["badge"], !isInteger(badge) {
            error("L08", "aps.badge must be an integer.")
        }
        if let level = aps["interruption-level"], !((level as? String).map(interruptionLevels.contains) ?? false) {
            error("L08", "aps.interruption-level must be one of passive, active, time-sensitive, critical.")
        }
        if ![1, 5, 10].contains(priority) {
            error("L08", "Priority must be 10, 5 or 1 (got \(priority)).")
        }

        if let token = context.deviceToken, !DeviceToken.isValid(token) {
            error("L09", "Device token must be an even-length hex string.")
        }

        if let environment = context.environment {
            if let known = context.knownEnvironment, known != environment {
                error("L10", "This token belongs to \(known.rawValue), but the push targets \(environment.rawValue).")
            }
            if let allowed = context.allowedEnvironments, !allowed.contains(environment) {
                error("L10", "The profile only allows \(allowed.map(\.rawValue).joined(separator: ", ")), not \(environment.rawValue).")
            }
        }

        if json[reservedKey] != nil {
            warn("L11", "Top-level key \"\(reservedKey)\" is reserved for receipt tracing.")
        }

        return (type, issues)
    }

    static func parse(_ payload: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    static func isInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(number)
    }

    static func largestField(_ json: [String: Any]) -> (String, Int) {
        var fields: [(String, Any)] = json.filter { $0.key != "aps" }.map { ($0.key, $0.value) }
        if let aps = json["aps"] as? [String: Any] { fields += aps.map { ("aps.\($0.key)", $0.value) } }
        return fields
            .map { name, value in (name, (try? JSONSerialization.data(withJSONObject: [name: value]))?.count ?? 0) }
            .max { $0.1 < $1.1 } ?? ("aps", 0)
    }
}
