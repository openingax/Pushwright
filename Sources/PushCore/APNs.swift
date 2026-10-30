import CryptoKit
import Foundation

public enum JWT {
    public static func make(teamId: String, keyId: String, privateKeyPEM: String, issuedAt: Date) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let header = try base64url(JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyId], options: .sortedKeys))
        let claims = try base64url(JSONSerialization.data(
            withJSONObject: ["iss": teamId, "iat": Int(issuedAt.timeIntervalSince1970)], options: .sortedKeys))
        let input = "\(header).\(claims)"
        // rawRepresentation is r‖s, the form ES256 JWTs use.
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return "\(input).\(base64url(signature))"
    }

    public static func isValidKey(_ pem: String) -> Bool {
        (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct APNsResponse: Sendable {
    public var status: Int
    public var apnsId: String?
    public var uniqueId: String?
    public var reason: String?
}

/// HTTP/2 client. One URLSession per (profile, environment): APNs rejects a second key on the same connection.
public final class APNsClient: @unchecked Sendable {
    public static let shared = APNsClient()

    /// Apple: refresh no more than once every 20 minutes and no less than once every 60.
    static let tokenLifetime: TimeInterval = 40 * 60

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var tokens: [String: (jwt: String, issuedAt: Date)] = [:]

    public func send(
        profile: Profile, environment: PushEnvironment, deviceToken: String, headers: [String: String], payload: Data
    ) async throws -> APNsResponse {
        var request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let session: URLSession
        switch profile.kind {
        case .token:
            request.setValue("bearer \(try jwt(for: profile))", forHTTPHeaderField: "authorization")
            session = cachedSession("\(profile.id)|\(environment.rawValue)") { URLSession(configuration: Self.configuration) }
        case .certificate:
            guard let sha = profile.certificateSHA256, let identity = Keychain.identity(sha256: sha) else {
                throw ErrorInfo.config("CREDENTIAL_MISSING", "The certificate for profile '\(profile.name)' is not in the Keychain.")
            }
            session = cachedSession("\(profile.id)|\(sha)|\(environment.rawValue)") {
                URLSession(configuration: Self.configuration, delegate: ClientCertificateDelegate(identity: identity), delegateQueue: nil)
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return APNsResponse(
            status: http.statusCode,
            apnsId: http.value(forHTTPHeaderField: "apns-id"),
            uniqueId: http.value(forHTTPHeaderField: "apns-unique-id"),
            reason: body?["reason"] as? String)
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    private func cachedSession(_ key: String, make: () -> URLSession) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] { return session }
        let session = make()
        sessions[key] = session
        return session
    }

    private func jwt(for profile: Profile) throws -> String {
        guard let teamId = profile.teamId, let keyId = profile.keyId else {
            throw ErrorInfo.config("PROFILE_INCOMPLETE", "Profile '\(profile.name)' has no Team ID or Key ID.")
        }
        let cacheKey = "\(profile.id)|\(keyId)|\(teamId)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = tokens[cacheKey], Date().timeIntervalSince(cached.issuedAt) < Self.tokenLifetime {
            return cached.jwt
        }
        guard let pem = try Keychain.privateKey(profileId: profile.id) else {
            throw ErrorInfo.config("CREDENTIAL_MISSING", "The .p8 key for profile '\(profile.name)' is not in the Keychain.")
        }
        let now = Date()
        let jwt = try JWT.make(teamId: teamId, keyId: keyId, privateKeyPEM: pem, issuedAt: now)
        tokens[cacheKey] = (jwt, now)
        return jwt
    }
}

private final class ClientCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let identity: SecIdentity

    init(identity: SecIdentity) { self.identity = identity }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }
}
