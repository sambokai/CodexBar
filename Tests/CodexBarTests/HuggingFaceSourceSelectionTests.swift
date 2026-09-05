import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct HuggingFaceSourceSelectionTests {
    @Test
    func `usage source defaults to auto and persists explicit modes`() throws {
        let fixture = try self.makeFixture(suite: "HuggingFaceSourceSelectionTests-persistence")
        let implementation = HuggingFaceProviderImplementation()
        let sourceContext = ProviderSourceModeContext(provider: .huggingface, settings: fixture.settings)
        let picker = try #require(implementation.settingsPickers(context: fixture.settingsContext())
            .first(where: { $0.id == "huggingface-usage-source" }))

        #expect(fixture.settings.huggingFaceUsageDataSource == .auto)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .huggingface)?.source == nil)
        #expect(implementation.sourceMode(context: sourceContext) == .auto)
        #expect(picker.options.map(\.id) == [
            ProviderSourceMode.auto.rawValue,
            ProviderSourceMode.web.rawValue,
            ProviderSourceMode.api.rawValue,
        ])

        picker.binding.wrappedValue = ProviderSourceMode.web.rawValue
        #expect(fixture.settings.huggingFaceUsageDataSource == .web)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .huggingface)?.source == .web)
        #expect(implementation.sourceMode(context: sourceContext) == .web)

        picker.binding.wrappedValue = ProviderSourceMode.api.rawValue
        #expect(fixture.settings.huggingFaceUsageDataSource == .api)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .huggingface)?.source == .api)
        #expect(implementation.sourceMode(context: sourceContext) == .api)

        picker.binding.wrappedValue = ProviderSourceMode.auto.rawValue
        #expect(fixture.settings.huggingFaceUsageDataSource == .auto)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .huggingface)?.source == nil)
        #expect(implementation.sourceMode(context: sourceContext) == .auto)
    }

    @Test
    func `web source remains selectable with api token and manual cookie`() throws {
        let fixture = try self.makeFixture(suite: "HuggingFaceSourceSelectionTests-manual-web")
        fixture.settings[providerConfig: .huggingface, field: .apiKey] = "hf_fixture_token"
        fixture.settings.huggingFaceCookieSource = .manual
        fixture.settings.huggingFaceManualCookieHeader = "hf_session=fixture"

        let implementation = HuggingFaceProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: fixture.settingsContext())
            .first(where: { $0.id == "huggingface-usage-source" }))
        picker.binding.wrappedValue = ProviderSourceMode.web.rawValue

        #expect(implementation.sourceMode(context: ProviderSourceModeContext(
            provider: .huggingface,
            settings: fixture.settings)) == .web)
        #expect(fixture.settings[providerConfig: .huggingface, field: .apiKey] == "hf_fixture_token")

        let snapshot = fixture.settings.huggingFaceSettingsSnapshot(tokenOverride: nil)
        #expect(snapshot.cookieSource == .manual)
        #expect(snapshot.manualCookieHeader == "hf_session=fixture")
    }

    private func makeFixture(suite: String) throws -> Fixture {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
        return Fixture(settings: settings, store: store)
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore

        func settingsContext() -> ProviderSettingsContext {
            ProviderSettingsContext(
                provider: .huggingface,
                settings: self.settings,
                store: self.store,
                boolBinding: { keyPath in
                    Binding(
                        get: { self.settings[keyPath: keyPath] },
                        set: { self.settings[keyPath: keyPath] = $0 })
                },
                stringBinding: { keyPath in
                    Binding(
                        get: { self.settings[keyPath: keyPath] },
                        set: { self.settings[keyPath: keyPath] = $0 })
                },
                statusText: { _ in nil },
                setStatusText: { _, _ in },
                lastAppActiveRunAt: { _ in nil },
                setLastAppActiveRunAt: { _, _ in },
                requestConfirmation: { _ in },
                runLoginFlow: {})
        }
    }
}
