import Foundation

public struct SendParams: Codable, Sendable {
    public var to: String
    /// JSON text.
    public var payload: String
    public var profile: String?
    public var environment: PushEnvironment?
    public var pushType: PushType?
    /// Full topic, or just the bundle ID (the push-type suffix is added).
    public var topic: String?
    public var priority: Int?
    public var expiration: Int?
    public var collapseId: String?
    public var dryRun: Bool?
    public var strict: Bool?

    public init(
        to: String, payload: String, profile: String? = nil, environment: PushEnvironment? = nil,
        pushType: PushType? = nil, topic: String? = nil, priority: Int? = nil, expiration: Int? = nil,
        collapseId: String? = nil, dryRun: Bool? = nil, strict: Bool? = nil
    ) {
        self.to = to
        self.payload = payload
        self.profile = profile
        self.environment = environment
        self.pushType = pushType
        self.topic = topic
        self.priority = priority
        self.expiration = expiration
        self.collapseId = collapseId
        self.dryRun = dryRun
        self.strict = strict
    }
}

public struct TargetSummary: Codable, Sendable {
    public var kind: String
    public var alias: String?
    public var environment: PushEnvironment?
    public var bundleId: String?
    public var token: String?
    public var udid: String?
    public var name: String?
}

public struct RequestSummary: Codable, Sendable {
    public var via: Via
    public var pushType: PushType
    public var topic: String?
    public var priority: Int?
    public var expiration: Int?
    public var collapseId: String?
    public var profile: String?
    public var bytes: Int
    public var apnsId: String?
}

public struct APNsSummary: Codable, Sendable {
    public var status: Int
    public var apnsId: String?
    public var uniqueId: String?
    public var reason: String?
}

/// What `send` returns, over the socket and as `pushwright send --json`.
public struct SendResult: Codable, Sendable {
    public var ok: Bool
    public var sendId: String?
    public var dryRun: Bool?
    public var target: TargetSummary?
    public var request: RequestSummary?
    public var apns: APNsSummary?
    public var simctlOutput: String?
    public var lint: [LintIssue]
    /// Equivalent command, dry runs only. Secrets are placeholders.
    public var command: String?
    public var error: ErrorInfo?

    public init(error: ErrorInfo, lint: [LintIssue] = []) {
        ok = false
        self.error = error
        self.lint = lint
    }

    init(ok: Bool, target: TargetSummary, request: RequestSummary, lint: [LintIssue]) {
        self.ok = ok
        self.target = target
        self.request = request
        self.lint = lint
    }
}

public struct ProfileStatus: Codable, Sendable {
    public var name: String
    public var kind: Profile.Kind
    public var credentialAvailable: Bool
}

public struct PingResult: Codable, Sendable {
    public var version: String
    public var pid: Int32
    public var profiles: [ProfileStatus]
}

public struct IPCRequest: Codable, Sendable {
    public var method: String
    public var send: SendParams?

    public init(method: String, send: SendParams? = nil) {
        self.method = method
        self.send = send
    }
}

/// Runs inside Pushwright.app, which holds the keys.
public enum Engine {
    public static func handle(_ request: Data) async -> Data {
        let response: any Encodable
        do {
            let request = try JSON.decode(IPCRequest.self, from: request)
            switch (request.method, request.send) {
            case ("ping", _): response = ping()
            case ("send", let params?): response = await send(params)
            default: response = SendResult(error: ErrorInfo(code: "BAD_REQUEST", message: "Unknown method \(request.method).", exitCode: ExitStatus.usage))
            }
        } catch {
            response = SendResult(error: ErrorInfo(code: "BAD_REQUEST", message: "\(error)", exitCode: ExitStatus.usage))
        }
        return (try? JSON.encode(response)) ?? Data()
    }

    public static func ping() -> PingResult {
        let profiles = (try? Store.loadProfiles()) ?? []
        return PingResult(version: PushCore.version, pid: ProcessInfo.processInfo.processIdentifier, profiles: profiles.map {
            let available = $0.kind == .token
                ? Keychain.hasPrivateKey(profileId: $0.id)
                : $0.certificateSHA256.flatMap(Keychain.identity(sha256:)) != nil
            return ProfileStatus(name: $0.name, kind: $0.kind, credentialAvailable: available)
        })
    }

    public static func send(_ params: SendParams) async -> SendResult {
        do {
            let payload = Data(params.payload.utf8)
            switch try resolveDestination(params.to, targets: Store.loadTargets()) {
            case let .simulator(simulator):
                return try sendToSimulator(simulator, params, payload)
            case let .device(alias, token, environment, bundleId):
                return try await sendToDevice(alias: alias, token: token, targetEnvironment: environment,
                                              targetBundleId: bundleId, params, payload)
            }
        } catch let error as ErrorInfo {
            return SendResult(error: error)
        } catch {
            return SendResult(error: ErrorInfo(code: "INTERNAL", message: "\(error)", exitCode: ExitStatus.apns))
        }
    }

    /// Adds the push-type suffix to a bare bundle ID. A wrong suffix is left alone so lint L03 reports it.
    public static func resolveTopic(_ base: String, _ type: PushType) -> String {
        let suffix = type.topicSuffix
        if suffix.isEmpty || base.hasSuffix(suffix) || Lint.knownSuffixes.contains(where: { base.hasSuffix($0) }) {
            return base
        }
        return base + suffix
    }

    enum Destination {
        case device(alias: String?, token: String, environment: PushEnvironment?, bundleId: String?)
        case simulator(BootedSimulator)
    }

    static func resolveDestination(_ to: String, targets: [Target]) throws -> Destination {
        if let target = targets.first(where: { $0.alias == to }) {
            return .device(alias: target.alias, token: target.token, environment: target.environment, bundleId: target.bundleId)
        }
        let token = DeviceToken.normalize(to)
        if token.count >= 32, DeviceToken.isValid(token) {
            return .device(alias: nil, token: token, environment: nil, bundleId: nil)
        }
        let simulators = Simctl.booted()
        if to == "booted", let first = simulators.first { return .simulator(first) }
        if let simulator = simulators.first(where: { $0.udid == to || $0.name == to }) { return .simulator(simulator) }
        throw ErrorInfo.config("UNKNOWN_TARGET", to == "booted"
            ? "No simulator is booted."
            : "No target '\(to)'. Use an alias from `pushwright targets`, a booted simulator (name, UDID or 'booted'), or a hex device token.")
    }

    static func resolveProfile(_ name: String?, _ profiles: [Profile]) throws -> Profile {
        if let name {
            guard let profile = profiles.first(where: { $0.name == name }) else {
                throw ErrorInfo.config("UNKNOWN_PROFILE", "No profile '\(name)'. Profiles: \(profiles.map(\.name).joined(separator: ", ")).")
            }
            return profile
        }
        switch profiles.count {
        case 0: throw ErrorInfo.config("NO_PROFILE", "No profile yet. Add a .p8 key or certificate in Pushwright Settings.")
        case 1: return profiles[0]
        default: throw ErrorInfo.config("PROFILE_REQUIRED", "Several profiles exist; pass --profile (\(profiles.map(\.name).joined(separator: ", "))).")
        }
    }

    static func blocking(_ issues: [LintIssue], strict: Bool) -> Bool {
        issues.contains { $0.level == .error || strict }
    }

    static func lintFailure(_ issues: [LintIssue]) -> SendResult {
        SendResult(error: ErrorInfo(code: "LINT_FAILED", message: "The payload or headers failed lint; nothing was sent.",
                                    exitCode: ExitStatus.lint), lint: issues)
    }

    static func sendToSimulator(_ simulator: BootedSimulator, _ params: SendParams, _ payload: Data) throws -> SendResult {
        let (type, issues) = Lint.check(payload, LintContext(pushType: params.pushType, priority: params.priority, collapseId: params.collapseId))
        if blocking(issues, strict: params.strict ?? false) { return lintFailure(issues) }
        guard type.simctlSupported else {
            throw ErrorInfo.config("SIMCTL_UNSUPPORTED", "simctl can only deliver alert and background pushes, not \(type.rawValue). Add the simulator's real APNs token as a target instead (Apple silicon, Xcode 14+).")
        }
        let embedded = Lint.parse(payload)?["Simulator Target Bundle"] as? String
        let profiles = (try? Store.loadProfiles()) ?? []
        guard let bundleId = params.topic ?? embedded ?? (profiles.count == 1 ? profiles[0].bundleId : nil) else {
            throw ErrorInfo.config("NO_TOPIC", "Pass --topic <bundle ID> so simctl knows which app gets the push.")
        }

        let target = TargetSummary(kind: "simulator", bundleId: bundleId, udid: simulator.udid, name: simulator.name)
        let request = RequestSummary(via: .simctl, pushType: type, topic: bundleId, bytes: payload.count)
        var result = SendResult(ok: true, target: target, request: request, lint: issues)
        if params.dryRun == true {
            result.dryRun = true
            result.command = "xcrun simctl push \(simulator.udid) \(bundleId) payload.apns"
            return result
        }

        let (status, output) = try Simctl.push(udid: simulator.udid, bundleId: bundleId, payload: payload)
        let record = SendRecord(sendId: makeSendId(), at: Date(), via: .simctl, target: simulator.name, pushType: type,
                                topic: bundleId, bytes: payload.count, ok: status == 0)
        try? Store.appendHistory(record)
        result.sendId = record.sendId
        result.simctlOutput = output
        if status != 0 {
            result.ok = false
            result.error = ErrorInfo(code: "SIMCTL_FAILED", message: output.isEmpty ? "simctl exited with \(status)." : output,
                                     exitCode: ExitStatus.apns)
        }
        return result
    }

    static func sendToDevice(
        alias: String?, token: String, targetEnvironment: PushEnvironment?, targetBundleId: String?,
        _ params: SendParams, _ payload: Data
    ) async throws -> SendResult {
        let profile = try resolveProfile(params.profile, Store.loadProfiles())
        let tokenHash = DeviceToken.hash(token)
        let lastSuccess = Store.lastSuccess(tokenHash: tokenHash)
        let known = targetEnvironment ?? lastSuccess?.environment
        let environment = params.environment ?? known ?? .sandbox
        let type = params.pushType ?? Lint.inferType(payload)
        guard let base = params.topic ?? targetBundleId ?? profile.bundleId else {
            throw ErrorInfo.config("NO_TOPIC", "No topic: pass --topic, or set a bundle ID on the target or profile.")
        }
        let topic = resolveTopic(base, type)
        let priority = params.priority ?? type.defaultPriority

        let (_, issues) = Lint.check(payload, LintContext(
            pushType: type, topic: topic, priority: priority, collapseId: params.collapseId, deviceToken: token,
            environment: environment, knownEnvironment: known, allowedEnvironments: profile.environments))
        if blocking(issues, strict: params.strict ?? false) { return lintFailure(issues) }

        // M1 has no approval flow yet, so every production request over the socket is refused.
        if environment == .production {
            throw ErrorInfo(code: "PRODUCTION_NEEDS_APPROVAL",
                            message: "Production pushes from the CLI need approval in Pushwright.app, which arrives in M2. Use --env sandbox for now.",
                            exitCode: ExitStatus.approval)
        }

        let apnsId = UUID().uuidString.lowercased()
        var headers = [
            "apns-push-type": type.rawValue, "apns-topic": topic, "apns-priority": "\(priority)",
            "apns-expiration": "\(params.expiration ?? 0)", "apns-id": apnsId,
        ]
        if let collapseId = params.collapseId { headers["apns-collapse-id"] = collapseId }

        let target = TargetSummary(kind: "device", alias: alias, environment: environment, bundleId: targetBundleId ?? profile.bundleId,
                                   token: DeviceToken.tail(token))
        let request = RequestSummary(via: .apns, pushType: type, topic: topic, priority: priority, expiration: params.expiration ?? 0,
                                     collapseId: params.collapseId, profile: profile.name, bytes: payload.count, apnsId: apnsId)
        var result = SendResult(ok: true, target: target, request: request, lint: issues)
        if params.dryRun == true {
            result.dryRun = true
            result.command = curl(environment: environment, headers: headers, payload: payload, kind: profile.kind)
            return result
        }

        let response: APNsResponse
        do {
            response = try await APNsClient.shared.send(profile: profile, environment: environment, deviceToken: token,
                                                        headers: headers, payload: payload)
        } catch let error as ErrorInfo {
            throw error
        } catch {
            throw ErrorInfo(code: "NETWORK_ERROR", message: error.localizedDescription, retryable: true, exitCode: ExitStatus.apns)
        }

        let record = SendRecord(
            sendId: makeSendId(), at: Date(), via: .apns, target: alias ?? "token", tokenTail: DeviceToken.tail(token),
            tokenHash: tokenHash, environment: environment, profile: profile.name, pushType: type, topic: topic,
            priority: priority, bytes: payload.count, status: response.status, apnsId: response.apnsId,
            uniqueId: response.uniqueId, reason: response.reason, ok: response.status == 200)
        try? Store.appendHistory(record)

        result.sendId = record.sendId
        result.apns = APNsSummary(status: response.status, apnsId: response.apnsId, uniqueId: response.uniqueId, reason: response.reason)
        guard response.status != 200 else { return result }

        let info = Explain.info(status: response.status, reason: response.reason)
        var cause = info.cause
        if response.reason == "BadDeviceToken", let lastSuccess, let lastEnvironment = lastSuccess.environment, lastEnvironment != environment {
            cause = "This token was accepted in \(lastEnvironment.rawValue) at \(lastSuccess.at.formatted(date: .abbreviated, time: .shortened)); this push went to \(environment.rawValue)."
        }
        result.ok = false
        result.error = ErrorInfo(code: info.code, message: "APNs rejected the push: \(response.status) \(response.reason ?? "")",
                                 status: response.status, reason: response.reason, cause: cause, fix: info.fix,
                                 retryable: info.retryable, exitCode: ExitStatus.apns)
        return result
    }

    static func curl(environment: PushEnvironment, headers: [String: String], payload: Data, kind: Profile.Kind) -> String {
        var parts = ["curl --http2"]
        parts.append(kind == .token ? "-H \"authorization: bearer $JWT\"" : "--cert-type P12 --cert \"$P12_FILE:$P12_PASSWORD\"")
        parts += headers.sorted { $0.key < $1.key }.map { "-H '\($0.key): \($0.value)'" }
        let body = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        parts.append("--data-binary '\(body)'")
        parts.append("\"https://\(environment.host)/3/device/$DEVICE_TOKEN\"")
        return parts.joined(separator: " \\\n  ")
    }

    static func makeSendId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "s_\(formatter.string(from: Date()))_\(String(format: "%04x", UInt16.random(in: 0 ... .max)))"
    }
}
