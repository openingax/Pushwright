import CryptoKit
import Foundation
import Testing
@testable import PushCore

// MARK: - JWT

@Test func jwtIsSignedWithES256() throws {
    let key = P256.Signing.PrivateKey()
    let jwt = try JWT.make(teamId: "TEAM123456", keyId: "KEY1234567", privateKeyPEM: key.pemRepresentation,
                           issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let parts = jwt.split(separator: ".").map(String.init)
    #expect(parts.count == 3)

    let header = try #require(decodeSegment(parts[0]))
    #expect(header["alg"] as? String == "ES256")
    #expect(header["kid"] as? String == "KEY1234567")
    let claims = try #require(decodeSegment(parts[1]))
    #expect(claims["iss"] as? String == "TEAM123456")
    #expect(claims["iat"] as? Int == 1_700_000_000)

    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(base64url(parts[2])))
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
}

@Test func rejectsBadKey() {
    #expect(!JWT.isValidKey("-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----"))
    #expect(JWT.isValidKey(P256.Signing.PrivateKey().pemRepresentation))
}

func base64url(_ segment: String) -> Data? {
    var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

func decodeSegment(_ segment: String) -> [String: Any]? {
    base64url(segment).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

// MARK: - Lint

struct LintCase: Sendable, CustomTestStringConvertible {
    var rule: String
    var payload: String
    var context = LintContext()
    var testDescription: String { "\(rule): \(payload.prefix(40))" }
}

let alert = #"{"aps":{"alert":"Hi"}}"#
let oversized = #"{"aps":{"alert":"\#(String(repeating: "x", count: 4100))"}}"#

@Test(arguments: [
    LintCase(rule: "L01", payload: "not json"),
    LintCase(rule: "L01", payload: #"{"foo":1}"#),
    LintCase(rule: "L02", payload: oversized),
    LintCase(rule: "L03", payload: alert, context: LintContext(pushType: .voip, topic: "com.example.app")),
    LintCase(rule: "L03", payload: alert, context: LintContext(topic: "com.example.app.voip")),
    LintCase(rule: "L04", payload: #"{"aps":{"content-available":1}}"#, context: LintContext(priority: 10)),
    LintCase(rule: "L05", payload: #"{"aps":{"event":"update"}}"#),
    LintCase(rule: "L05", payload: #"{"aps":{"timestamp":1793347200,"event":"start","content-state":{}}}"#),
    LintCase(rule: "L06", payload: #"{"aps":{"timestamp":1793347200000,"event":"end"}}"#),
    LintCase(rule: "L07", payload: #"{"aps":{"mutable-content":1}}"#),
    LintCase(rule: "L08", payload: #"{"aps":{"alert":"Hi","badge":"1"}}"#),
    LintCase(rule: "L08", payload: #"{"aps":{"alert":"Hi","interruption-level":"urgent"}}"#),
    LintCase(rule: "L08", payload: alert, context: LintContext(collapseId: String(repeating: "c", count: 65))),
    LintCase(rule: "L08", payload: alert, context: LintContext(priority: 7)),
    LintCase(rule: "L09", payload: alert, context: LintContext(deviceToken: "abc")),
    LintCase(rule: "L10", payload: alert, context: LintContext(environment: .production, knownEnvironment: .sandbox)),
    LintCase(rule: "L10", payload: alert, context: LintContext(environment: .production, allowedEnvironments: [.sandbox])),
    LintCase(rule: "L11", payload: #"{"aps":{"alert":"Hi"},"pushwright":{}}"#),
])
func lintReportsRule(_ testCase: LintCase) {
    let issues = Lint.check(Data(testCase.payload.utf8), testCase.context).issues
    #expect(issues.contains { $0.rule == testCase.rule }, "got \(issues.map(\.rule))")
}

@Test func backgroundWithSoundIsRejected() {
    let issues = Lint.check(Data(#"{"aps":{"content-available":1,"sound":"default"}}"#.utf8),
                            LintContext(pushType: .background)).issues
    #expect(issues.contains { $0.rule == "L04" })
}

@Test func cleanRequestHasNoIssues() {
    let context = LintContext(
        topic: "com.example.app", priority: 10, collapseId: "order-42", deviceToken: String(repeating: "ab", count: 32),
        environment: .sandbox, knownEnvironment: .sandbox, allowedEnvironments: [.sandbox])
    #expect(Lint.check(Data(#"{"aps":{"alert":{"title":"Hi","body":"There"},"badge":1,"sound":"default"}}"#.utf8), context).issues.isEmpty)
    let liveActivity = #"{"aps":{"timestamp":1793347200,"event":"update","content-state":{"progress":0.5}}}"#
    #expect(Lint.check(Data(liveActivity.utf8), LintContext(topic: "com.example.app.push-type.liveactivity")).issues.isEmpty)
}

@Test func infersPushType() {
    #expect(Lint.inferType(Data(alert.utf8)) == .alert)
    #expect(Lint.inferType(Data(#"{"aps":{"content-available":1}}"#.utf8)) == .background)
    #expect(Lint.inferType(Data(#"{"aps":{"event":"end","timestamp":1}}"#.utf8)) == .liveactivity)
}

// MARK: - Topics and tokens

@Test func addsTopicSuffix() {
    #expect(Engine.resolveTopic("com.example.app", .voip) == "com.example.app.voip")
    #expect(Engine.resolveTopic("com.example.app.voip", .voip) == "com.example.app.voip")
    #expect(Engine.resolveTopic("com.example.app", .liveactivity) == "com.example.app.push-type.liveactivity")
    #expect(Engine.resolveTopic("com.example.app", .alert) == "com.example.app")
    // A wrong suffix is kept so L03 can report it.
    #expect(Engine.resolveTopic("com.example.app.voip", .alert) == "com.example.app.voip")
}

@Test func normalizesLoggedTokens() {
    #expect(DeviceToken.normalize("<AB12 cd34>") == "ab12cd34")
    #expect(DeviceToken.isValid("ab12cd34"))
    #expect(!DeviceToken.isValid("ab1"))
    #expect(!DeviceToken.isValid("zz"))
}

// MARK: - Explain

@Test func errorCodesAreUniqueAndReadable() throws {
    #expect(Set(Explain.all.map(\.code)).count == Explain.all.count)
    let info = try #require(Explain.info(for: "BadDeviceToken"))
    #expect(info.code == "APNS_BAD_DEVICE_TOKEN")
    #expect(info.status == 400)
}

@Test func retryFollowsApple() {
    for reason in ["BadDeviceToken", "DeviceTokenNotForTopic", "Forbidden", "ExpiredToken", "Unregistered", "PayloadTooLarge"] {
        #expect(Explain.info(for: reason)?.retryable == false, "\(reason)")
    }
    #expect(Explain.info(for: "TooManyRequests")?.retryable == true)
}

@Test func unknownReasonFallsBack() {
    #expect(Explain.info(status: 400, reason: "SomethingNew").code == "APNS_SOMETHING_NEW")
    #expect(Explain.info(status: 502, reason: nil).code == "APNS_HTTP_502")
}
