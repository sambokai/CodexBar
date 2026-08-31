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
    func `current billing period spend and identity match the finite API payload`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        let snapshot = try await Self.fetch(engine: engine, transport: transport)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.providerCost?.used == 2.41)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.nextRegenAmount == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.providerID == .huggingface)
        #expect(snapshot.identity?.accountEmail == "fixture@example.com")
        #expect(snapshot.identity?.accountID == "fixture-user")
        #expect(snapshot.identity?.loginMethod == "PRO")
        #expect(snapshot.detailRow(label: "Billing period")?.value == "2026-08-01 – 2026-09-01")
        #expect(snapshot.detailRow(label: "Reported spend")?.value == "$2.41")
        #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
        #expect(snapshot.details.map(\.title) == ["Billing summary", "Usage breakdown"])
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$1.75", "$0.66"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing parser reports only the selected usage endpoint categories`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Self.transport()
        let snapshot = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()

        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.detailRow(label: "Reported spend")?.value == "$2.41")
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(requests.map { $0.url?.path } == [
            "/api/whoami-v2",
            "/api/settings/billing/usage",
        ])
        #expect(requests.allSatisfy { $0.url?.path != "/api/settings/billing/usage-v2" })
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.costUsage == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `current billing period aggregates categories exactly once`(engine: ProviderPluginEngineKind) async throws {
        let usage = Self.usageBody(
            endpoints: #"[{"totalCostMicroUSD":7654321}]"#,
            spaces: #"[{"totalCostMicroUSD":1234567}]"#)
        let snapshot = try await Self.fetch(
            engine: engine,
            billingBody: Self.billingBody(usage: usage))

        #expect(snapshot.providerCost?.used == 8.888888)
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.resetsAt == Self.date("2026-09-01T00:00:00Z"))
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$7.65", "$1.23"])
        #expect(snapshot.details.map(\.title) == ["Billing summary", "Usage breakdown"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero usage remains a valid exact spend snapshot`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine,
            billingBody: Self.billingBody(usage: Self.usageBody(endpoints: "[]", spaces: "[]")))

        #expect(snapshot.providerCost?.used == 0)
        #expect(snapshot.providerCost?.period == "Reported billing period")
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.details.last?.rows.map(\.label) == ["Endpoints", "Spaces"])
        #expect(snapshot.details.last?.rows.map(\.value) == ["$0.00", "$0.00"])
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free grant does not create a quota or balance snapshot`(engine: ProviderPluginEngineKind) async throws {
        let usage = Self.usageBody(
            endpoints: #"[{"totalCostMicroUSD":500000,"freeGrant":true}]"#,
            spaces: "[]")
        let snapshot = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))

        #expect(snapshot.providerCost?.used == 0.5)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.nextRegenAmount == nil)
        #expect(snapshot.providerCost?.limit == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `only a positively known PRO plan is rendered`(engine: ProviderPluginEngineKind) async throws {
        let profiles = [
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":true}"#,
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":false}"#,
            #"{"name":"fixture-user","email":"fixture@example.com"}"#,
            #"{"name":"fixture-user","email":"fixture@example.com","isPro":null}"#,
        ]

        for (index, profile) in profiles.enumerated() {
            let snapshot = try await Self.fetch(engine: engine, profileBody: profile)
            if index == 0 {
                #expect(snapshot.identity?.loginMethod == "PRO")
                #expect(snapshot.detailRow(label: "Plan")?.value == "PRO")
            } else {
                #expect(snapshot.identity?.loginMethod == nil)
                #expect(snapshot.detailRow(label: "Plan") == nil)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed plan type is classified as a parse failure`(engine: ProviderPluginEngineKind) async throws {
        do {
            _ = try await Self.fetch(
                engine: engine,
                profileBody: #"{"name":"fixture-user","isPro":"PRO"}"#)
            Issue.record("Expected a malformed Hugging Face plan type to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected Hugging Face error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed cost values are classified as parse failures`(engine: ProviderPluginEngineKind) async throws {
        let usages = [
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":"1"}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":-1}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{}]"#, spaces: "[]"),
            Self.usageBody(endpoints: #"[{"totalCostMicroUSD":1e309}]"#, spaces: "[]"),
            Self.usageBody(
                endpoints: #"[{"totalCostMicroUSD":9007199254740991},{"totalCostMicroUSD":1}]"#,
                spaces: "[]"),
        ]

        for usage in usages {
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
        let malformedUsages = [
            #"{"Endpoints":{},"Spaces":[]}"#,
            #"{"Endpoints":[null],"Spaces":[]}"#,
            #"{"Endpoints":[[]],"Spaces":[]}"#,
            #"{"Endpoints":[],"Spaces":null}"#,
        ]
        for usage in malformedUsages {
            do {
                _ = try await Self.fetch(engine: engine, billingBody: Self.billingBody(usage: usage))
                Issue.record("Expected malformed Hugging Face usage data to fail: \(usage)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face usage error: \(error)")
            }
        }

        let malformedPeriods = [
            ("not-a-date", "2026-09-01T00:00:00Z"),
            ("2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z"),
        ]
        for (start, end) in malformedPeriods {
            do {
                _ = try await Self.fetch(
                    engine: engine,
                    billingBody: Self.billingBody(periodStart: start, periodEnd: end))
                Issue.record("Expected malformed Hugging Face billing period to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            } catch {
                Issue.record("Unexpected Hugging Face period error: \(error)")
            }
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
            ("billing", 418, .apiFailure),
            ("billing", 429, .rateLimited),
            ("billing", 503, .providerUnavailable),
        ]

        for (resource, status, expectedKind) in cases {
            do {
                _ = try await Self.fetch(
                    engine: engine,
                    profileBody: resource == "identity" ? #"{"error":"hf_fixture_token"}"# : Self.profileFixture,
                    billingBody: resource == "billing" ? #"{"error":"hf_fixture_token"}"# : Self.billingFixture,
                    profileStatus: resource == "identity" ? status : 200,
                    billingStatus: resource == "billing" ? status : 200)
                Issue.record("Expected Hugging Face HTTP \(status) to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == expectedKind)
                #expect(!error.message.contains("hf_fixture_token"))
                if resource == "billing", status == 401 {
                    #expect(error.message.contains("personal billing usage"))
                } else if resource == "identity", status == 401 {
                    #expect(error.message.contains("user access token"))
                }
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
            "/api/settings/billing/usage",
        ])
        for request in requests {
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture_token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(!url.absoluteString.contains("hf_fixture_token"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing endpoint does not depend on the account name`(engine: ProviderPluginEngineKind) async throws {
        let transport = Self.transport(profileBody: #"{"name":"fixture/user?x","email":"fixture@example.com"}"#)
        _ = try await Self.fetch(engine: engine, transport: transport)
        let requests = await transport.requests()
        let billingRequest = try #require(requests.last)
        #expect(billingRequest.url?.path == "/api/settings/billing/usage")
        #expect(billingRequest.url?.absoluteString.contains("fixture") == false)
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
        #expect(descriptor.metadata.creditsHint == "Spend reported by Hugging Face billing")
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

    @Test @MainActor
    func `billing spend remains visible when cost summary is disabled`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 2.41,
                limit: 0,
                currencyCode: "USD",
                period: "Reported billing period",
                resetsAt: Self.date("2026-09-01T00:00:00Z"),
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .huggingface,
            metadata: HuggingFaceProviderDescriptor.descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Reported billing period: $2.41")
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
        let runtime = try BundledPluginTestSupport.runtime("huggingface", engine: engine, transport: transport)
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
            let isBilling = url.path == "/api/settings/billing/usage"
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
        periodStart: String = "2026-08-01T00:00:00Z",
        periodEnd: String = "2026-09-01T00:00:00Z",
        usage: String = Self.billingUsageFixture) -> String
    {
        "{\"period\":{\"periodStart\":\"\(periodStart)\",\"periodEnd\":\"\(periodEnd)\"},\"usage\":\(usage)}"
    }

    private static func usageBody(endpoints: String, spaces: String) -> String {
        "{\"Endpoints\":\(endpoints),\"Spaces\":\(spaces)}"
    }

    private static let profileFixture = #"{"name":"fixture-user","email":"fixture@example.com","isPro":true}"#

    private static let billingUsageFixture = #"""
    {"Endpoints":[
        {"entityId":"endpoint-fixture-a","label":"Endpoint A","product":"inference-endpoints",
         "unitLabel":"compute","productPrettyName":"Endpoint","unitCostMicroUSD":100,
         "active":true,"quantity":10000,"totalCostMicroUSD":1000000,
         "startedAt":"2026-08-03T00:00:00Z","stoppedAt":"2026-08-04T00:00:00Z"},
        {"entityId":"endpoint-fixture-b","label":"Endpoint B","product":"inference-endpoints",
         "unitLabel":"compute","productPrettyName":"Endpoint","unitCostMicroUSD":100,
         "active":true,"quantity":7500,"totalCostMicroUSD":750000,
         "startedAt":"2026-08-05T00:00:00Z","stoppedAt":"2026-08-06T00:00:00Z"}],
        "Spaces":[
        {"entityId":"space-fixture","label":"Space","product":"spaces",
         "unitLabel":"compute","productPrettyName":"Space","unitCostMicroUSD":100,
         "active":false,"quantity":6600,"totalCostMicroUSD":660000,
        "startedAt":"2026-08-10T00:00:00Z","stoppedAt":"2026-08-11T00:00:00Z"}]}
    """#

    private static let billingFixture = Self.billingBody()
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
