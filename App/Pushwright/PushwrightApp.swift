import AppKit
import PushCore
import SwiftUI

@main
struct PushwrightApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Pushwright", systemImage: "bell.badge") {
            MenuContent(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.serverError.map { "Not listening: \($0)" } ?? "Listening for CLI requests")
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Install Command Line Tool") { model.installCLI() }
        if let note = model.cliNote { Text(note) }
        Divider()
        Button("Quit Pushwright") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@Observable
final class AppModel {
    var profiles: [Profile] = []
    var targets: [Target] = []
    var serverError: String?
    var cliNote: String?
    var lastError: String?

    private let server = SocketServer(path: Store.socketPath) { await Engine.handle($0) }

    init() {
        profiles = (try? Store.loadProfiles()) ?? []
        targets = (try? Store.loadTargets()) ?? []
        do {
            try server.start()
        } catch {
            serverError = (error as? ErrorInfo)?.message ?? error.localizedDescription
        }
    }

    func addTokenProfile(name: String, teamId: String, keyId: String, bundleId: String,
                         environments: [PushEnvironment], pem: String) throws {
        try validateName(name)
        guard teamId.count == 10, keyId.count == 10 else { throw UserError("Team ID and Key ID are both 10 characters.") }
        guard !environments.isEmpty else { throw UserError("Pick at least one environment.") }
        guard JWT.isValidKey(pem) else { throw UserError("That file is not a valid .p8 key.") }
        let profile = Profile(name: name, kind: .token, teamId: teamId, keyId: keyId,
                              bundleId: bundleId.isEmpty ? nil : bundleId, environments: environments)
        try Keychain.savePrivateKey(pem, profileId: profile.id, label: "Pushwright: \(name)")
        profiles.append(profile)
        try Store.saveProfiles(profiles)
    }

    func addCertificateProfile(_ identity: PushIdentity, name: String) throws {
        try validateName(name)
        profiles.append(Profile(name: name, kind: .certificate, certificateSHA256: identity.sha256,
                                certificateName: identity.name, bundleId: identity.bundleId,
                                environments: identity.environments))
        try Store.saveProfiles(profiles)
    }

    func removeProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        if profile.kind == .token { Keychain.deletePrivateKey(profileId: id) }
        profiles.removeAll { $0.id == id }
        persist { try Store.saveProfiles(profiles) }
    }

    func addTarget(alias: String, token: String, environment: PushEnvironment, bundleId: String) throws {
        let token = DeviceToken.normalize(token)
        guard !alias.isEmpty, !alias.contains(" "), alias != "booted" else {
            throw UserError("Pick a one-word alias other than 'booted'.")
        }
        guard !targets.contains(where: { $0.alias == alias }) else { throw UserError("Alias '\(alias)' is taken.") }
        guard DeviceToken.isValid(token) else { throw UserError("The token must be hex, as printed by the app.") }
        targets.append(Target(alias: alias, token: token, environment: environment, bundleId: bundleId.isEmpty ? nil : bundleId))
        try Store.saveTargets(targets)
    }

    func removeTarget(_ id: Target.ID) {
        targets.removeAll { $0.id == id }
        persist { try Store.saveTargets(targets) }
    }

    /// Links ~/.local/bin/pushwright to the CLI inside this app bundle.
    func installCLI() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pushwright")
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
        let link = bin.appending(path: "pushwright")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
            cliNote = "Linked ~/.local/bin/pushwright (add ~/.local/bin to PATH if needed)."
        } catch {
            cliNote = "Could not link the CLI: \(error.localizedDescription)"
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty else { throw UserError("Give the profile a name.") }
        guard !profiles.contains(where: { $0.name == name }) else { throw UserError("Profile '\(name)' already exists.") }
    }

    private func persist(_ save: () throws -> Void) {
        do { try save() } catch { lastError = error.localizedDescription }
    }
}

struct UserError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
