import Foundation

/// Resolves the Nous Portal access token CodexBar uses for read-only billing lookups.
///
/// Nous Portal issues short-lived OAuth access tokens through the Hermes Agent device-code login. Refresh tokens
/// are single-use and the portal revokes the whole session when it detects reuse, so CodexBar never refreshes:
/// it only reads the access token Hermes already minted (`~/.hermes/auth.json`) or an explicit environment
/// override, and reports a clear "run `hermes`" message once that token expires.
public enum NousSettingsReader: Sendable {
    public static let accessTokenEnvironmentKey = "NOUS_PORTAL_ACCESS_TOKEN"
    public static let portalBaseURLEnvironmentKeys = ["NOUS_PORTAL_BASE_URL", "HERMES_PORTAL_BASE_URL"]
    public static let hermesHomeEnvironmentKey = "HERMES_HOME"
    public static let defaultPortalBaseURL = URL(string: "https://portal.nousresearch.com")!
    /// Tokens closer to expiry than this are treated as expired so a fetch never races the portal clock.
    public static let expirySkew: TimeInterval = 60

    public enum CredentialSource: Sendable, Equatable {
        case environment
        case authFile(String)

        public var label: String {
            switch self {
            case .environment: "env"
            case .authFile: "hermes"
            }
        }
    }

    public struct Credential: Sendable, Equatable {
        public let token: String
        public let portalBaseURL: URL
        public let expiresAt: Date?
        public let source: CredentialSource

        public init(token: String, portalBaseURL: URL, expiresAt: Date?, source: CredentialSource) {
            self.token = token
            self.portalBaseURL = portalBaseURL
            self.expiresAt = expiresAt
            self.source = source
        }

        public func isExpired(now: Date = Date(), skew: TimeInterval = NousSettingsReader.expirySkew) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= skew
        }
    }

    /// Returns a usable (non-expired) credential, or nil when none is configured.
    public static func credential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> Credential?
    {
        try? self.resolveCredential(environment: environment, now: now)
    }

    /// Resolves the credential, throwing a typed error that explains what is missing or expired.
    public static func resolveCredential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) throws -> Credential
    {
        if let token = self.cleaned(environment[self.accessTokenEnvironmentKey]) {
            return Credential(
                token: token,
                portalBaseURL: self.portalBaseURL(environment: environment, stored: nil),
                expiresAt: self.jwtExpiry(token),
                source: .environment)
        }

        var expired: Credential?
        var sawFile = false
        for url in self.authFileCandidates(environment: environment) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            sawFile = true
            guard let data = try? Data(contentsOf: url),
                  let stored = self.parseAuthFile(data: data)
            else { continue }
            let credential = Credential(
                token: stored.token,
                portalBaseURL: self.portalBaseURL(environment: environment, stored: stored.portalBaseURL),
                expiresAt: stored.expiresAt ?? self.jwtExpiry(stored.token),
                source: .authFile(url.path))
            if credential.isExpired(now: now) {
                expired = expired ?? credential
                continue
            }
            return credential
        }

        if let expired, case let .authFile(path) = expired.source {
            throw NousUsageError.sessionExpired(path)
        }
        throw sawFile
            ? NousUsageError.authFileInvalid(self.authFileCandidates(environment: environment).first?.path ?? "")
            : NousUsageError.missingCredentials
    }

    public static func unavailableMessage(environment: [String: String]) -> String? {
        do {
            _ = try self.resolveCredential(environment: environment)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public static func portalBaseURL(environment: [String: String], stored: String?) -> URL {
        for key in self.portalBaseURLEnvironmentKeys {
            if let raw = self.cleaned(environment[key]), let url = self.normalizedHTTPSURL(raw) {
                return url
            }
        }
        if let stored, let url = self.normalizedHTTPSURL(stored) {
            return url
        }
        return self.defaultPortalBaseURL
    }

    // MARK: - Hermes auth store

    struct StoredCredential: Equatable {
        let token: String
        let portalBaseURL: String?
        let expiresAt: Date?
    }

    /// Hermes stores per-profile credentials in `auth.json` and a cross-profile copy in `shared/nous_auth.json`.
    static func authFileCandidates(environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let override = self.cleaned(environment[self.hermesHomeEnvironmentKey]) {
            roots.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true))
        }
        roots.append(self.defaultHermesHome(environment: environment))

        var seen = Set<String>()
        var candidates: [URL] = []
        for root in roots {
            for relative in ["auth.json", "shared/nous_auth.json"] {
                let url = root.appendingPathComponent(relative)
                if seen.insert(url.path).inserted {
                    candidates.append(url)
                }
            }
        }
        return candidates
    }

    static func defaultHermesHome(environment: [String: String]) -> URL {
        let home: URL = if let raw = self.cleaned(environment["HOME"]) {
            URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".hermes", isDirectory: true)
    }

    /// Accepts the three shapes Hermes writes: `providers.nous`, `credential_pool.nous[]`, or a bare state object.
    static func parseAuthFile(data: Data) -> StoredCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let providers = root["providers"] as? [String: Any],
           let nous = providers["nous"] as? [String: Any],
           let stored = self.storedCredential(from: nous)
        {
            return stored
        }
        if let pool = root["credential_pool"] as? [String: Any],
           let entries = pool["nous"] as? [[String: Any]]
        {
            for entry in entries {
                if let stored = self.storedCredential(from: entry) {
                    return stored
                }
            }
        }
        return self.storedCredential(from: root)
    }

    private static func storedCredential(from state: [String: Any]) -> StoredCredential? {
        guard let token = self.cleaned(state["access_token"] as? String) else { return nil }
        return StoredCredential(
            token: token,
            portalBaseURL: self.cleaned(state["portal_base_url"] as? String),
            expiresAt: (state["expires_at"] as? String).flatMap(Self.parseISODate))
    }

    // MARK: - Helpers

    static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Best-effort `exp` claim from a JWT so environment overrides also get expiry checks.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func normalizedHTTPSURL(_ raw: String) -> URL? {
        var value = raw
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host != nil else { return nil }
        guard scheme == "https" || (scheme == "http" && (url.host == "localhost" || url.host == "127.0.0.1")) else {
            return nil
        }
        return url
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
