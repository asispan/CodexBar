import Foundation
import Testing
@testable import CodexBarCore

struct NousSettingsReaderTests {
    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".hermes/shared", isDirectory: true),
            withIntermediateDirectories: true)
        return home
    }

    private static func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private static func authJSON(token: String, expiresAt: String, portal: String = "https://portal.nousresearch.com") -> String {
        """
        {
          "version": 1,
          "providers": {
            "nous": {
              "access_token": "\(token)",
              "refresh_token": "rt",
              "portal_base_url": "\(portal)",
              "expires_at": "\(expiresAt)"
            }
          }
        }
        """
    }

    @Test
    func `environment token overrides hermes auth file`() throws {
        let home = try Self.makeHome()
        try Self.write(
            Self.authJSON(token: "file-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        let credential = try NousSettingsReader.resolveCredential(environment: [
            "HOME": home.path,
            "NOUS_PORTAL_ACCESS_TOKEN": "env-token",
            "NOUS_PORTAL_BASE_URL": "https://preview.portal.example.com/",
        ])
        #expect(credential.token == "env-token")
        #expect(credential.source == .environment)
        #expect(credential.portalBaseURL.absoluteString == "https://preview.portal.example.com")
    }

    @Test
    func `reads providers section from hermes auth file`() throws {
        let home = try Self.makeHome()
        let path = home.appendingPathComponent(".hermes/auth.json")
        try Self.write(Self.authJSON(token: "file-token", expiresAt: "2999-01-01T00:00:00+00:00"), to: path)

        let credential = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        #expect(credential.token == "file-token")
        #expect(credential.source == .authFile(path.path))
        #expect(credential.portalBaseURL == NousSettingsReader.defaultPortalBaseURL)
        #expect(credential.expiresAt == NousSettingsReader.parseISODate("2999-01-01T00:00:00+00:00"))
    }

    @Test
    func `HERMES_HOME override takes precedence over default home`() throws {
        let home = try Self.makeHome()
        let custom = home.appendingPathComponent("custom-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Self.write(
            Self.authJSON(token: "default-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        try Self.write(
            Self.authJSON(token: "custom-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: custom.appendingPathComponent("auth.json"))

        let credential = try NousSettingsReader.resolveCredential(environment: [
            "HOME": home.path,
            "HERMES_HOME": custom.path,
        ])
        #expect(credential.token == "custom-token")
    }

    @Test
    func `falls back to shared store when profile token is expired`() throws {
        let home = try Self.makeHome()
        try Self.write(
            Self.authJSON(token: "stale", expiresAt: "2000-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        try Self.write(
            """
            { "_schema": 1, "access_token": "shared-token", "expires_at": "2999-01-01T00:00:00+00:00" }
            """,
            to: home.appendingPathComponent(".hermes/shared/nous_auth.json"))

        let credential = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        #expect(credential.token == "shared-token")
    }

    @Test
    func `expired token reports session expired instead of missing`() throws {
        let home = try Self.makeHome()
        let path = home.appendingPathComponent(".hermes/auth.json")
        try Self.write(Self.authJSON(token: "stale", expiresAt: "2000-01-01T00:00:00+00:00"), to: path)

        #expect(NousSettingsReader.credential(environment: ["HOME": home.path]) == nil)
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        } throws: { error in
            error as? NousUsageError == .sessionExpired(path.path)
        }
        #expect(NousSettingsReader.unavailableMessage(environment: ["HOME": home.path])?.contains("expired") == true)
    }

    @Test
    func `missing auth file reports missing credentials`() throws {
        let home = try Self.makeHome()
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        } throws: { error in
            error as? NousUsageError == .missingCredentials
        }
    }

    @Test
    func `credential pool entries are accepted when providers section is absent`() throws {
        let data = Data("""
        {
          "credential_pool": {
            "nous": [
              { "id": "a", "auth_type": "oauth", "access_token": "pool-token", "expires_at": "2999-01-01T00:00:00+00:00" }
            ]
          }
        }
        """.utf8)
        let stored = try #require(NousSettingsReader.parseAuthFile(data: data))
        #expect(stored.token == "pool-token")
        #expect(stored.portalBaseURL == nil)
    }

    @Test
    func `jwt exp claim is used when no expiry is stored`() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let payload = Data("{\"exp\": 946684800}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "\(header).\(payload).sig"
        #expect(NousSettingsReader.jwtExpiry(token) == Date(timeIntervalSince1970: 946_684_800))

        let credential = NousSettingsReader.Credential(
            token: token,
            portalBaseURL: NousSettingsReader.defaultPortalBaseURL,
            expiresAt: NousSettingsReader.jwtExpiry(token),
            source: .environment)
        #expect(credential.isExpired(now: Date(timeIntervalSince1970: 946_684_800 + 10)))
        #expect(!credential.isExpired(now: Date(timeIntervalSince1970: 946_684_800 - 600)))
    }

    @Test
    func `portal base URL rejects non-https overrides`() {
        #expect(NousSettingsReader.portalBaseURL(environment: ["NOUS_PORTAL_BASE_URL": "http://evil.example"], stored: nil)
            == NousSettingsReader.defaultPortalBaseURL)
        #expect(NousSettingsReader.portalBaseURL(environment: [:], stored: "https://stored.example/")
            .absoluteString == "https://stored.example")
    }
}
