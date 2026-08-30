import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HuggingFaceUsageStatsTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `current billing period spend and identity match the API payload`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        let snapshot = try await Self.fetch(engine: engine, transport: transport)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.providerCost?.used == 1.75)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Current billing period")
        #expect(snapshot.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.providerID == .huggingface)
        #expect(snapshot.identity?.accountEmail == "fixture@example.com")
        #expect(snapshot.identity?.accountID == "fixture-user")
        #expect(snapshot.identity?.loginMethod == "PRO")
        #expect(snapshot.detailRow(label: "Current period")?.value == "2026-08-01 – 2026-09-01")
        #expect(snapshot.detailRow(label: "Current spend")?.value == "$1.75")
        #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
        #expect(snapshot.details.last?.title == "Usage breakdown")
        #expect(snapshot.details.last?.rows.map(\.label) == ["Inference", "Spaces Serverless"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$1.25", "$0.50"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero free usage remains a valid exact spend snapshot`(engine: ProviderPluginEngineKind) async throws {
        let billing = Self.billingBody(
            usage: #"{"inference":[{"freeGrant":true,"totalCostMicroUSD":0}]}"#)
        let snapshot = try await Self.fetch(engine: engine, billingBody: billing)

        #expect(snapshot.providerCost?.used == 0)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.details.last?.rows.map(\.label) == ["Inference"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$0.00"])
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed cost values are classified as parse failures`(engine: ProviderPluginEngineKind) async throws {
        let usageBodies = [
            #"{"inference":[{"totalCostMicroUSD":"1"}]}"#,
            #"{"inference":[{"totalCostMicroUSD":-1}]}"#,
            #"{"inference":[{}]}"#,
            #"{"inference":[{"totalCostMicroUSD":1e309}]}"#,
        ]

        for usage in usageBodies {
            do {
                _ = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))
                Issue.record("Expected malformed Hugging Face cost to fail: \(usage)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed usage categories and billing dates are classified as parse failures`(
        engine: ProviderPluginEngineKind) async throws
    {
        let malformedUsage = [
            #"[]"#,
            #"{"inference":{}}"#,
            #"{"inference":[null]}"#,
        ]
        for usage in malformedUsage {
            do {
                _ = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))
                Issue.record("Expected malformed Hugging Face usage to fail: \(usage)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face error: \(error)")
            }
        }

        let malformedDate = Self.billingBody(
            usage: #"{"inference":[{"totalCostMicroUSD":1}]}"#,
            periodStart: "not-a-date")
        do {
            _ = try await Self.fetch(engine: engine, billingBody: malformedDate)
            Issue.record("Expected malformed Hugging Face period date to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected Hugging Face error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors preserve the documented classifications`(engine: ProviderPluginEngineKind) async throws {
        let cases: [(String, Int, ProviderFetchClassifiedError.Kind)] = [
            ("identity", 401, .authenticationExpired),
            ("identity", 503, .providerUnavailable),
            ("billing", 401, .authenticationExpired),
            ("billing", 403, .permissionDenied),
            ("billing", 404, .apiFailure),
            ("billing", 429, .rateLimited),
            ("billing", 503, .providerUnavailable),
        ]

        for (resource, status, expectedKind) in cases {
            do {
                _ = try await Self.fetch(
                    engine: engine,
                    profileStatus: resource == "identity" ? status : 200,
                    billingStatus: resource == "billing" ? status : 200)
                Issue.record("Expected Hugging Face HTTP \(status) to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == expectedKind)
                #expect(!error.message.contains("hf_fixture_token"))
            } catch {
                Issue.record("Unexpected Hugging Face HTTP error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `requests stay on the official origin and carry only the bearer token`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        _ = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()

        #expect(requests.count == 2)
        #expect(requests.map { $0.url?.path } == [
            "/api/whoami-v2",
            "/api/users/fixture-user/billing/usage/live",
        ])
        for request in requests {
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture_token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(!url.absoluteString.contains("hf_fixture_token"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `user names are encoded as one billing path segment`(engine: ProviderPluginEngineKind) async throws {
        let transport = Self.transport(profileBody: #"{"name":"fixture/user?x","email":"fixture@example.com"}"#)
        _ = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()
        let billingRequest = try #require(requests.last)
        #expect(billingRequest.url?.absoluteString.contains("/api/users/fixture%2Fuser%3Fx/billing/usage/live") == true)
    }

    @Test
    func `descriptor and credentials expose only the scoped API surface`() async throws {
        #expect(HuggingFaceSettingsReader.token(environment: [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "  'hf_fixture_token'  ",
        ]) == "hf_fixture_token")
        #expect(HuggingFaceSettingsReader.token(environment: [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "  \"  \" ",
        ]) == nil)

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)
        #expect(descriptor.metadata.displayName == "Hugging Face")
        #expect(descriptor.metadata.shortDisplayName == "HF")
        #expect(descriptor.metadata.sessionLabel == "Spend")
        #expect(descriptor.metadata.weeklyLabel == "Spend")
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.metadata.isPrimaryProvider == false)
        #expect(descriptor.metadata.supportsCredits == false)
        #expect(descriptor.tokenCost.supportsTokenCost == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.name == "huggingface")
        #expect(descriptor.cli.aliases == ["hf"])
        #expect(descriptor.metadata.dashboardURL == "https://huggingface.co/settings/billing")
        #expect(descriptor.metadata.statusPageURL == nil)
        #expect(descriptor.metadata.statusLinkURL == nil)

        let config = ProviderConfig(id: .huggingface, apiKey: "configured-token")
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [HuggingFaceSettingsReader.tokenEnvironmentKey: "environment-token"],
            provider: .huggingface,
            config: config)
        #expect(environment[HuggingFaceSettingsReader.tokenEnvironmentKey] == "configured-token")
        #expect(ProviderTokenResolver.token(for: .huggingface, environment: environment) == "configured-token")
        #expect(TokenAccountSupportCatalog.envOverride(for: .huggingface, token: "account-token") == [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "account-token",
        ])

        let context = Self.fetchContext(environment: [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token",
        ])
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let strategy = try #require(strategies.first)
        #expect(strategies.map(\.id) == ["huggingface.js"])
        #expect(strategy.kind == .apiToken)
        #expect(await strategy.isAvailable(context))
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        transport: ProviderHTTPTransportStub? = nil,
        profileBody: String = Self.profileFixture,
        billingBody: String = Self.billingFixture,
        profileStatus: Int = 200,
        billingStatus: Int = 200) async throws -> UsageSnapshot
    {
        let transport = transport ?? Self.transport(
            profileBody: profileBody,
            billingBody: billingBody,
            profileStatus: profileStatus,
            billingStatus: billingStatus)
        let runtime = try BundledPluginTestSupport.runtime(
            "huggingface",
            engine: engine,
            transport: transport)
        return try await runtime.fetchUsage(
            secrets: [HuggingFaceSettingsReader.tokenEnvironmentKey: "hf_fixture_token"],
            now: Date(timeIntervalSince1970: 1_777_000_000))
    }

    private static func transport(
        profileBody: String = Self.profileFixture,
        billingBody: String = Self.billingFixture,
        profileStatus: Int = 200,
        billingStatus: Int = 200) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isBilling = url.path.contains("/billing/usage/live")
            return try Self.response(
                url: url,
                body: isBilling ? billingBody : profileBody,
                statusCode: isBilling ? billingStatus : profileStatus)
        }
    }

    private static func response(url: URL, body: String, statusCode: Int) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func fetchContext(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: HuggingFaceTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func billingBody(
        usage: String,
        periodStart: String = "2026-08-01T00:00:00Z",
        periodEnd: String = "2026-09-01T00:00:00Z") -> String
    {
        """
        {"period":{"periodStart":"\(periodStart)","periodEnd":"\(periodEnd)"},"usage":\(usage)}
        """
    }

    private static let profileFixture = #"{"name":"fixture-user","email":"fixture@example.com","isPro":true}"#

    private static let billingFixture = #"""
    {
      "period": {"periodStart":"2026-08-01T00:00:00Z","periodEnd":"2026-09-01T00:00:00Z"},
      "usage": {
        "inference": [{
          "entityId":"entity-inference",
          "label":"fixture",
          "product":"inference",
          "quantity":1,
          "startedAt":"2026-08-10T00:00:00Z",
          "stoppedAt":"2026-08-10T00:01:00Z",
          "freeGrant":false,
          "productPrettyName":"Inference",
          "unitLabel":"USD",
          "totalCostMicroUSD":1250000,
          "unitCostMicroUSD":1250000,
          "active":false
        }],
        "spaces_serverless": [{"entityId":"entity-space","totalCostMicroUSD":500000}]
      }
    }
    """#
}

@MainActor
struct HuggingFaceProviderSettingsTests {
    @Test
    func `settings expose one secure API token field`() throws {
        let suite = "HuggingFaceProviderSettingsTests-token"
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
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .huggingface,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})

        let implementation = HuggingFaceProviderImplementation()
        let fields = implementation.settingsFields(context: context)
        #expect(fields.count == 1)
        let field = try #require(fields.first)
        #expect(field.id == "huggingface-api-token")
        #expect(field.title == "API token")
        #expect(field.kind == .secure)
        #expect(field.placeholder == "hf_...")

        field.binding.wrappedValue = "hf_fixture_token"
        #expect(settings[providerConfig: .huggingface, field: .apiKey] == "hf_fixture_token")
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .huggingface,
            settings: settings,
            environment: [:])))
    }
}

private struct HuggingFaceTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
