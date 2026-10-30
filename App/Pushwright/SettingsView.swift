import PushCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ProfilesTab(model: model).tabItem { Label("Profiles", systemImage: "key") }
            TargetsTab(model: model).tabItem { Label("Targets", systemImage: "iphone") }
        }
        .frame(width: 600, height: 400)
    }
}

// MARK: - Profiles

struct ProfilesTab: View {
    let model: AppModel
    @State private var selection: Profile.ID?
    @State private var addingKey = false
    @State private var addingCertificate = false

    var body: some View {
        VStack(alignment: .leading) {
            List(model.profiles, selection: $selection) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).bold()
                    Text(summary(profile)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add .p8 Key…") { addingKey = true }
                Button("Add Certificate…") { addingCertificate = true }
                Spacer()
                Button("Remove", role: .destructive) {
                    if let selection { model.removeProfile(selection) }
                }
                .disabled(selection == nil)
            }
            if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .sheet(isPresented: $addingKey) { AddKeySheet(model: model) }
        .sheet(isPresented: $addingCertificate) { AddCertificateSheet(model: model) }
    }

    func summary(_ profile: Profile) -> String {
        let credential = profile.kind == .token
            ? "Key \(profile.keyId ?? "?") · Team \(profile.teamId ?? "?")"
            : profile.certificateName ?? "Certificate"
        let environments = profile.environments.map(\.rawValue).joined(separator: " + ")
        return [credential, environments, profile.bundleId ?? "no bundle ID"].joined(separator: " · ")
    }
}

struct AddKeySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var teamId = ""
    @State private var keyId = ""
    @State private var bundleId = ""
    @State private var sandbox = true
    @State private var production = false
    @State private var pem: String?
    @State private var fileName: String?
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            LabeledContent(".p8 key") {
                HStack {
                    Text(fileName ?? "None").foregroundStyle(.secondary)
                    Button("Choose…") { importing = true }
                }
            }
            TextField("Key ID", text: $keyId)
            TextField("Team ID", text: $teamId)
            TextField("Bundle ID (default topic)", text: $bundleId)
            Toggle("Sandbox", isOn: $sandbox)
            Toggle("Production", isOn: $production)
            Text("Tick only the environments this key may use. A sandbox-only key is the safe choice for agents.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(pem == nil || name.isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            guard case let .success(url) = result else { return }
            pem = try? String(contentsOf: url, encoding: .utf8)
            fileName = url.lastPathComponent
            // Apple names downloads AuthKey_<KEYID>.p8.
            let stem = url.deletingPathExtension().lastPathComponent
            if keyId.isEmpty, stem.hasPrefix("AuthKey_") { keyId = String(stem.dropFirst("AuthKey_".count)) }
            if name.isEmpty { name = stem }
        }
    }

    func add() {
        guard let pem else { return }
        let environments = (sandbox ? [PushEnvironment.sandbox] : []) + (production ? [.production] : [])
        do {
            try model.addTokenProfile(name: name, teamId: teamId.trimmingCharacters(in: .whitespaces),
                                      keyId: keyId.trimmingCharacters(in: .whitespaces),
                                      bundleId: bundleId.trimmingCharacters(in: .whitespaces),
                                      environments: environments, pem: pem)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddCertificateSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var identities: [PushIdentity] = []
    @State private var selection: PushIdentity.ID?
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Push certificates in your keychain").bold()
            if identities.isEmpty {
                Text("None found. Double-click the .p12 file to import it into the login keychain, then reopen this sheet.")
                    .foregroundStyle(.secondary)
            }
            List(identities, selection: $selection) { identity in
                VStack(alignment: .leading) {
                    Text(identity.name)
                    Text(identity.environments.map(\.rawValue).joined(separator: " + ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)
            TextField("Profile name", text: $name)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(selection == nil || name.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear { identities = Keychain.pushIdentities() }
        .onChange(of: selection) {
            if name.isEmpty, let identity = identities.first(where: { $0.id == selection }) { name = identity.bundleId ?? identity.name }
        }
    }

    func add() {
        guard let identity = identities.first(where: { $0.id == selection }) else { return }
        do {
            try model.addCertificateProfile(identity, name: name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Targets

struct TargetsTab: View {
    let model: AppModel
    @State private var selection: Target.ID?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading) {
            List(model.targets, selection: $selection) { target in
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.alias).bold()
                    Text([target.environment.rawValue, target.bundleId ?? "no bundle ID", DeviceToken.tail(target.token)]
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Device…") { adding = true }
                Text("Booted simulators need no entry.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) {
                    if let selection { model.removeTarget(selection) }
                }
                .disabled(selection == nil)
            }
            if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .sheet(isPresented: $adding) { AddTargetSheet(model: model) }
    }
}

struct AddTargetSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var token = ""
    @State private var environment = PushEnvironment.sandbox
    @State private var bundleId = ""
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Alias", text: $alias)
            TextField("Device token (hex)", text: $token)
            Picker("Environment", selection: $environment) {
                Text("Sandbox").tag(PushEnvironment.sandbox)
                Text("Production").tag(PushEnvironment.production)
            }
            .pickerStyle(.segmented)
            Text("Development-signed builds register sandbox tokens; TestFlight and App Store builds register production tokens.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Bundle ID", text: $bundleId)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(alias.isEmpty || token.isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }

    func add() {
        do {
            try model.addTarget(alias: alias.trimmingCharacters(in: .whitespaces), token: token, environment: environment,
                                bundleId: bundleId.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
