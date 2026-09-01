import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct SettingsStoreKeychainPreferenceTests {
    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func `local keychain preference wins and shared defaults fill only an absent value`(
        localValue: Bool?, sharedValue: Bool?)
    {
        let local = InMemoryUserDefaults()
        let shared = InMemoryUserDefaults()
        if let localValue {
            local.set(localValue, forKey: "debugDisableKeychainAccess")
        }
        if let sharedValue {
            shared.set(sharedValue, forKey: "debugDisableKeychainAccess")
        }

        let disabled = SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local, sharedDefaults: shared)

        #expect(disabled == (localValue ?? sharedValue ?? false))
        #expect(local.object(forKey: "debugDisableKeychainAccess") as? Bool == (localValue ?? sharedValue))
        #expect(shared.object(forKey: "debugDisableKeychainAccess") as? Bool == sharedValue)
    }

    @Test
    func `ordinary tests never invoke the shared defaults resolver`() throws {
        try #require(SettingsStore.isRunningTests)
        var resolutions = 0
        let shared = SettingsStore.resolveSharedDefaults {
            resolutions += 1
            return InMemoryUserDefaults()
        }

        #expect(shared == nil)
        #expect(resolutions == 0)
        #expect(SettingsStore.sharedDefaults == nil)
        let local = InMemoryUserDefaults()
        #expect(!SettingsStore.shouldBridgeSharedDefaults(for: local))
        #expect(!SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local))
        #expect(local.dictionaryRepresentation().isEmpty)
    }

    @Test
    func `settings initialization leaves app group migration untouched and fresh defaults adaptive`() throws {
        let local = InMemoryUserDefaults()
        try self.withSettingsStore(defaults: local) { store in
            #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            #expect(local.object(forKey: "widgetSelectedProvider") == nil)
            #expect(!store.debugDisableKeychainAccess)
            #expect(store.refreshFrequency == .adaptive)
            // Config/secret migration remains independent of app-group migration.
            #expect(local.bool(forKey: "codexbar.legacySecretsMigrationCompleted"))

            store.debugDisableKeychainAccess = true
            #expect(local.bool(forKey: "debugDisableKeychainAccess"))
            store.debugDisableKeychainAccess = false
            #expect(!local.bool(forKey: "debugDisableKeychainAccess"))
            #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            #expect(SettingsStore.sharedDefaults == nil)
        }
    }

    @Test(arguments: ["providerDetectionCompleted", AppGroupSupport.migrationVersionKey])
    func `existing launch markers still keep the legacy refresh default`(marker: String) throws {
        let local = InMemoryUserDefaults()
        local.set(1, forKey: marker)
        try self.withSettingsStore(defaults: local) { store in
            #expect(store.refreshFrequency == .fiveMinutes)
            #expect(local.integer(forKey: marker) == 1)
            if marker != AppGroupSupport.migrationVersionKey {
                #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            }
        }
    }

    private func withSettingsStore(
        defaults: InMemoryUserDefaults,
        operation: (SettingsStore) throws -> Void) throws
    {
        // Fail before constructing settings if the caller deliberately opted into live user state.
        try #require(SettingsStore.isRunningTests)
        try #require(KeychainTestSafety.resolveShouldBlockRealKeychainAccess(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment))
        try #require(!KeychainAccessGate.isDisabledByEnvironment())
        try #require(KeychainAccessGate.processDisableReason == nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreKeychainPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove synthetic settings fixture: \(error)")
            }
        }
        let previousOverride = KeychainAccessGate.currentOverrideForTesting
        defer {
            if let previousOverride {
                KeychainAccessGate.isDisabled = previousOverride
            } else {
                KeychainAccessGate.resetOverrideForTesting()
            }
        }
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json")),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                fileURL: root.appendingPathComponent("antigravity.json")),
            performInitialProviderDetection: false)
        defer { store.configFileWatcher?.stop() }
        try operation(store)
    }
}
