import ArgumentParser
import Foundation
import PushCore

extension PushEnvironment: ExpressibleByArgument {}
extension PushType: ExpressibleByArgument {}

public struct Pushwright: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pushwright",
        abstract: "Send and check APNs test pushes. Pushwright.app holds the keys; this CLI asks it to send.",
        discussion: """
            Exit codes: 0 ok · 1 APNs/simctl rejected · 2 lint failed · 4 needs approval · 5 configuration · 64 usage.
            Every command takes --json for machine-readable output.
            """,
        version: PushCore.version,
        subcommands: [Send.self, LintCommand.self, Targets.self, Profiles.self, History.self, ExplainCommand.self, Doctor.self])

    public init() {}

    /// Entry point for the executable. Called from here, where ArgumentParser is imported, `main` resolves to the
    /// async overload; from main.swift it resolved to the sync one, which cannot run async subcommands.
    public static func launch() async {
        await main(nil)
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a push to a device token or a booted simulator.",
        discussion: """
            Examples:
              pushwright send alert.apns --to iphone
              pushwright send alert.apns --to booted --topic com.example.app
              echo '{"aps":{"alert":"Hi"}}' | pushwright send - --to 5f2c...a91c --topic com.example.app --dry-run
            Push type, topic suffix and priority are inferred when omitted.
            """)

    @Argument(help: "Payload file (.apns or .json), or - to read stdin.") var payload: String
    @Option(help: "Target alias, booted simulator (name, UDID or 'booted'), or hex device token.") var to: String
    @Option(help: "Profile name; needed when there is more than one.") var profile: String?
    @Option(help: "sandbox or production. Defaults to the target's environment, else sandbox.") var env: PushEnvironment?
    @Option(help: "Push type. Inferred from the payload when omitted.") var type: PushType?
    @Option(help: "apns-topic, or just the bundle ID (the push-type suffix is added).") var topic: String?
    @Option(help: "10, 5 or 1.") var priority: Int?
    @Option(help: "apns-expiration in UNIX seconds. Default 0: deliver once, don't store.") var expiration: Int?
    @Option(help: "apns-collapse-id, up to 64 bytes.") var collapseId: String?
    @Flag(help: "Resolve and lint the request and print an equivalent command, without sending.") var dryRun = false
    @Flag(help: "Treat lint warnings as errors.") var strict = false
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let params = SendParams(
            to: to, payload: try readPayload(payload), profile: profile, environment: env, pushType: type, topic: topic,
            priority: priority, expiration: expiration, collapseId: collapseId, dryRun: dryRun, strict: strict)
        let result: SendResult
        do {
            result = try JSON.decode(SendResult.self, from: IPCClient.call(IPCRequest(method: "send", send: params)))
        } catch let error as ErrorInfo {
            result = SendResult(error: error)
        }
        if json { try printJSON(result) } else { printHuman(result) }
        if let error = result.error { throw ExitCode(error.exitCode) }
    }

    func printHuman(_ result: SendResult) {
        let target = result.target.map(describe) ?? to
        if result.ok, result.dryRun == true {
            print("Dry run, nothing sent: \(target)")
            if let request = result.request { print(describe(request)) }
        } else if result.ok {
            print("✓ Sent to \(target)" + (result.apns.map { " — \($0.status), apns-id \($0.apnsId ?? "?")" } ?? ""))
            if let uniqueId = result.apns?.uniqueId { print("  apns-unique-id \(uniqueId) (look it up in Apple's Push Notifications Console)") }
        }
        printLint(result.lint)
        if let command = result.command { print("\n" + command) }
        if let error = result.error { printError(error) }
    }

    func describe(_ target: TargetSummary) -> String {
        if target.kind == "simulator" { return "simulator \(target.name ?? target.udid ?? "")" }
        return "\(target.alias ?? target.token ?? "device") (\(target.environment?.rawValue ?? "?"))"
    }

    func describe(_ request: RequestSummary) -> String {
        var parts = ["via \(request.via.rawValue)", request.pushType.rawValue, request.topic ?? "", "\(request.bytes) bytes"]
        if let priority = request.priority { parts.append("priority \(priority)") }
        if let profile = request.profile { parts.append("profile \(profile)") }
        return "  " + parts.joined(separator: " · ")
    }
}

struct LintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint", abstract: "Check a payload locally, without sending.")

    @Argument(help: "Payload file, or - to read stdin.") var payload: String
    @Option(help: "Push type. Inferred from the payload when omitted.") var type: PushType?
    @Option(help: "apns-topic or bundle ID, to check the suffix.") var topic: String?
    @Option(help: "10, 5 or 1.") var priority: Int?
    @Flag(help: "Treat warnings as errors.") var strict = false
    @Flag(help: "Print JSON.") var json = false

    struct Output: Encodable {
        var ok: Bool
        var pushType: PushType
        var bytes: Int
        var issues: [LintIssue]
    }

    func run() throws {
        let data = Data(try readPayload(payload).utf8)
        let resolvedType = type ?? Lint.inferType(data)
        let (pushType, issues) = Lint.check(data, LintContext(
            pushType: resolvedType, topic: topic.map { Engine.resolveTopic($0, resolvedType) }, priority: priority))
        let ok = !issues.contains { $0.level == .error || strict }
        if json {
            try printJSON(Output(ok: ok, pushType: pushType, bytes: data.count, issues: issues))
        } else {
            print(ok ? "✓ \(pushType.rawValue), \(data.count) bytes" : "✗ \(pushType.rawValue), \(data.count) bytes")
            printLint(issues)
        }
        if !ok { throw ExitCode(ExitStatus.lint) }
    }
}

struct Targets: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List device targets and booted simulators.")

    @Flag(help: "Print JSON.") var json = false

    struct Device: Encodable {
        var alias: String
        var environment: PushEnvironment
        var bundleId: String?
        var token: String
    }

    struct Output: Encodable {
        var devices: [Device]
        var simulators: [BootedSimulator]
    }

    func run() throws {
        let devices = try Store.loadTargets().map {
            Device(alias: $0.alias, environment: $0.environment, bundleId: $0.bundleId, token: DeviceToken.tail($0.token))
        }
        let output = Output(devices: devices, simulators: Simctl.booted())
        if json { return try printJSON(output) }
        print("Devices (add them in Pushwright Settings):")
        if devices.isEmpty { print("  none") }
        for device in devices {
            print("  \(device.alias)  \(device.environment.rawValue)  \(device.bundleId ?? "-")  \(device.token)")
        }
        print("Booted simulators (use the name, UDID or 'booted'):")
        if output.simulators.isEmpty { print("  none") }
        for simulator in output.simulators { print("  \(simulator.name)  \(simulator.runtime)  \(simulator.udid)") }
    }
}

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sending profiles. Keys stay in the app's Keychain.")

    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let profiles = try Store.loadProfiles()
        if json { return try printJSON(profiles) }
        if profiles.isEmpty { print("No profiles. Add a .p8 key or certificate in Pushwright Settings.") }
        for profile in profiles {
            let credential = profile.kind == .token
                ? "key \(profile.keyId ?? "?"), team \(profile.teamId ?? "?")"
                : profile.certificateName ?? "certificate"
            let environments = profile.environments.map(\.rawValue).joined(separator: "+")
            print("\(profile.name)  \(credential)  \(environments)  \(profile.bundleId ?? "-")")
        }
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent sends.")

    @Option(help: "How many records.") var last = 20
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let records = Store.history(last: last)
        if json { return try printJSON(records) }
        if records.isEmpty { print("No sends yet.") }
        for record in records {
            let status = record.status.map(String.init) ?? (record.ok ? "ok" : "failed")
            let target = [record.target, record.environment?.rawValue].compactMap { $0 }.joined(separator: "/")
            print("\(record.at.formatted(date: .numeric, time: .standard))  \(record.ok ? "✓" : "✗") \(status)  \(record.via.rawValue)  \(target)  \(record.pushType.rawValue)  \(record.topic ?? "")  \(record.reason ?? "")")
        }
    }
}

struct ExplainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain", abstract: "Explain an APNs error reason, e.g. BadDeviceToken. Lists all reasons when omitted.")

    @Argument(help: "APNs reason string.") var reason: String?
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        guard let reason else {
            if json { return try printJSON(Explain.all) }
            for info in Explain.all { print("\(info.status)  \(info.reason)") }
            return
        }
        guard let info = Explain.info(for: reason) else {
            print("Unknown reason '\(reason)'. Run `pushwright explain` to list them.")
            throw ExitCode(ExitStatus.usage)
        }
        if json { return try printJSON(info) }
        print("\(info.reason) (\(info.status), \(info.code))")
        print("  cause: \(info.cause)")
        print("  fix:   \(info.fix)")
        print("  retry: \(info.retryable ? "after fixing the cause" : "no, Apple says not to")")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that the app, credentials and simctl are ready.")

    @Flag(help: "Print JSON.") var json = false

    struct Check: Encodable {
        var name: String
        var ok: Bool
        var detail: String
    }

    func run() throws {
        var checks: [Check] = []
        do {
            let ping = try JSON.decode(PingResult.self, from: IPCClient.call(IPCRequest(method: "ping")))
            checks.append(Check(name: "app", ok: true, detail: "Pushwright \(ping.version) is running (pid \(ping.pid))."))
            checks.append(Check(name: "profiles", ok: !ping.profiles.isEmpty, detail: ping.profiles.isEmpty
                ? "No profile. Add a .p8 key or certificate in Pushwright Settings."
                : ping.profiles.map(\.name).joined(separator: ", ")))
            let missing = ping.profiles.filter { !$0.credentialAvailable }.map(\.name)
            checks.append(Check(name: "credentials", ok: missing.isEmpty, detail: missing.isEmpty
                ? "Every profile's key or certificate is in the Keychain."
                : "Missing in the Keychain: \(missing.joined(separator: ", ")). Re-add them in Settings."))
        } catch {
            checks.append(Check(name: "app", ok: false, detail: (error as? ErrorInfo)?.message ?? "\(error)"))
        }
        let targets = (try? Store.loadTargets()) ?? []
        checks.append(Check(name: "targets", ok: true, detail: "\(targets.count) device target(s); simulators need none."))
        let simctl = Simctl.isAvailable()
        checks.append(Check(name: "simctl", ok: simctl, detail: simctl
            ? "\(Simctl.booted().count) simulator(s) booted."
            : "xcrun simctl failed. Install Xcode and run xcode-select -s."))

        let ok = checks.allSatisfy(\.ok)
        if json {
            struct Output: Encodable { var ok: Bool; var checks: [Check] }
            try printJSON(Output(ok: ok, checks: checks))
        } else {
            for check in checks { print("\(check.ok ? "✓" : "✗") \(check.name): \(check.detail)") }
        }
        if !ok { throw ExitCode(ExitStatus.config) }
    }
}

// MARK: - Output

func readPayload(_ path: String) throws -> String {
    let data = path == "-"
        ? FileHandle.standardInput.readDataToEndOfFile()
        : try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    return String(decoding: data, as: UTF8.self)
}

func printJSON<T: Encodable>(_ value: T) throws {
    print(String(decoding: try JSON.encode(value, pretty: true), as: UTF8.self))
}

func printLint(_ issues: [LintIssue]) {
    for issue in issues { print("  [\(issue.rule) \(issue.level.rawValue)] \(issue.message)") }
}

func printError(_ error: ErrorInfo) {
    var lines = ["✗ \(error.code): \(error.message)"]
    if let cause = error.cause { lines.append("  cause: \(cause)") }
    if let fix = error.fix { lines.append("  fix:   \(fix)") }
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}
