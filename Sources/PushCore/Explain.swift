import Foundation

public struct APNsErrorInfo: Codable, Sendable {
    public var reason: String
    public var status: Int
    public var code: String
    public var cause: String
    public var fix: String
    /// False for the reasons Apple says never to retry.
    public var retryable: Bool
}

/// APNs error reasons with likely causes and fixes (Apple docs, 2026-10).
public enum Explain {
    static let doNotRetry: Set = [
        "BadDeviceToken", "DeviceTokenNotForTopic", "Forbidden", "ExpiredToken", "Unregistered", "PayloadTooLarge",
    ]

    static let bug = "This is a Pushwright bug; please report it."

    static let table: [(status: Int, reason: String, cause: String, fix: String)] = [
        (400, "BadCollapseId", "apns-collapse-id is longer than 64 bytes.", "Use a collapse ID of 64 bytes or less."),
        (400, "BadDeviceToken",
         "The token is invalid. Most often it belongs to the other environment: development-signed builds register sandbox tokens, TestFlight and App Store builds register production tokens.",
         "Send to the environment the token came from (--env), or get a fresh token from the matching build."),
        (400, "BadExpirationDate", "apns-expiration is not a valid UNIX time in seconds.", "Pass seconds since 1970, or 0."),
        (400, "BadMessageId", "apns-id is not a lowercase 8-4-4-4-12 UUID.", bug),
        (400, "BadPriority", "apns-priority is not 10, 5 or 1.", "Use --priority 10, 5 or 1."),
        (400, "BadTopic", "apns-topic is malformed or has the wrong suffix for this push type.",
         "Check --topic. Pass just the bundle ID and Pushwright adds the suffix."),
        (400, "DeviceTokenNotForTopic", "The token belongs to an app whose bundle ID differs from the topic.",
         "Use the bundle ID of the app that registered this token."),
        (400, "DuplicateHeaders", "A header was sent more than once.", bug),
        (400, "IdleTimeout", "The connection sat idle too long.", "Retry; a new connection is opened."),
        (400, "InvalidPushType", "apns-push-type is not a valid value.", "Use one of: \(PushType.allCases.map(\.rawValue).joined(separator: ", "))."),
        (400, "MissingDeviceToken", "The request path has no device token.", "Pass a token or target alias with --to."),
        (400, "MissingTopic", "apns-topic is required because the certificate covers several topics.",
         "Pass --topic, or set a bundle ID on the target or profile."),
        (400, "PayloadEmpty", "The payload is empty.", "Send a JSON object with an aps dictionary."),
        (400, "TopicDisallowed", "This key or certificate may not push to this topic.",
         "Check that the key or certificate belongs to the team that owns this bundle ID."),
        (403, "BadCertificate", "The client certificate is invalid.", "Re-export the push certificate, or switch the profile to a .p8 key."),
        (403, "BadCertificateEnvironment", "The certificate is not valid for this environment.",
         "Use the other environment, or a Sandbox & Production certificate."),
        (403, "ExpiredProviderToken", "The JWT is more than an hour old; the Mac clock is usually off.",
         "Check the system clock. Pushwright makes a new token automatically."),
        (403, "Forbidden", "This action is not allowed.", "Check the key's permissions in your developer account."),
        (403, "InvalidProviderToken", "The JWT is invalid: wrong Key ID or Team ID, or the key was revoked.",
         "Check the profile's Key ID and Team ID, then run `pushwright doctor`."),
        (403, "MissingProviderToken", "No certificate and no authorization header were sent.", "Give the profile a .p8 key or a certificate."),
        (403, "UnrelatedKeyIdInToken", "A different key was used on a connection opened with another key.", bug),
        (403, "BadEnvironmentKeyIdInToken", "The key is restricted to the other environment.",
         "Use a profile whose key allows this environment."),
        (404, "BadPath", "The request path is invalid.", bug),
        (405, "MethodNotAllowed", "The request method is not POST.", bug),
        (410, "ExpiredToken", "The device token has expired.", "Get a new token from the device."),
        (410, "Unregistered", "The token is no longer active for this topic (app deleted or notifications reset).",
         "Get a new token from the device."),
        (413, "PayloadTooLarge", "The payload is over the limit (4096 bytes, VoIP 5120).",
         "Shrink the payload; `pushwright lint` names the largest field."),
        (429, "TooManyProviderTokenUpdates", "The JWT was replaced more than once in 20 minutes.", bug),
        (429, "TooManyRequests", "Too many pushes to the same device token in a row.", "Wait a little, then send again."),
        (500, "InternalServerError", "APNs had an internal error.", "Retry later with back-off."),
        (503, "ServiceUnavailable", "APNs is unavailable.", "Retry later with back-off."),
        (503, "Shutdown", "The APNs server is shutting down.", "Retry; a new connection is opened."),
    ]

    public static let all: [APNsErrorInfo] = table.map {
        APNsErrorInfo(reason: $0.reason, status: $0.status, code: code(for: $0.reason), cause: $0.cause, fix: $0.fix,
                      retryable: !doNotRetry.contains($0.reason))
    }

    public static func info(for reason: String) -> APNsErrorInfo? {
        all.first { $0.reason == reason }
    }

    /// Falls back to a generic entry for reasons Apple adds later.
    public static func info(status: Int, reason: String?) -> APNsErrorInfo {
        if let reason, let known = info(for: reason) { return known }
        return APNsErrorInfo(reason: reason ?? "", status: status, code: reason.map(code(for:)) ?? "APNS_HTTP_\(status)",
                             cause: "APNs returned \(status) \(reason ?? "").", fix: "See Apple's APNs error documentation.",
                             retryable: status >= 500 || status == 429)
    }

    /// BadDeviceToken -> APNS_BAD_DEVICE_TOKEN
    static func code(for reason: String) -> String {
        var out = "APNS"
        for (index, char) in reason.enumerated() {
            if char.isUppercase || index == 0 { out += "_" }
            out += char.uppercased()
        }
        return out
    }
}
