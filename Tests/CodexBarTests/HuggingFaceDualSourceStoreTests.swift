import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

/// FP-194 store-level dual-source coverage: the per-account Auto fetch may only prove a *local*
/// bearer/browser identity match; global uniqueness is decided by the batch post-pass, and
/// provider-level wallet state follows deterministic publication rules.
private struct HuggingFaceWalletOutcomeStubStrategy: ProviderFetchStrategy {
    enum Mode: Sendable {
        case compose(Set<UUID>)
        case providerLevelUnverified
        case unavailable
        case failAPI
    }

    let mode: Mode
    let balanceUSD: Double

    let id = "huggingface.js"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        switch self.mode {
        case .failAPI:
            throw ProviderPluginError.script("fixture API outage")
        case .unavailable:
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.unavailable)
        case .providerLevelUnverified:
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: self.balanceUSD,
                    observedAt: Date(),
                    attribution: .unverified)))
        case let .compose(matchingAccountIDs):
            let isLocalMatch = context.selectedTokenAccountID.map { matchingAccountIDs.contains($0) } ?? false
            if isLocalMatch {
                let observedAt = Date()
                let usage = Self.apiUsage(context: context, balanceUSD: self.balanceUSD, observedAt: observedAt)
                return self.makeResult(usage: usage, sourceLabel: "api+web")
                    .replacingWalletOutcome(.localMatchComposed(
                        balanceUSD: self.balanceUSD,
                        observedAt: observedAt))
            }
            let usage = Self.apiUsage(context: context, balanceUSD: nil)
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: self.balanceUSD,
                    observedAt: Date(),
                    attribution: .unverified)))
        }
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func apiUsage(
        context _: ProviderFetchContext,
        balanceUSD: Double?,
        observedAt: Date? = nil) -> UsageSnapshot
    {
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Reported billing period",
            balance: balanceUSD,
            balanceUpdatedAt: observedAt,
            updatedAt: Date())
        return UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: Date(), identity: nil)
    }
}

@MainActor
@Suite(.serialized)
struct HuggingFaceDualSourceStoreTests {
    @Test
    func `stacked batch composes the wallet only for the uniquely matching account`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-unique",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [0])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.count == 2)
        #expect(snapshots[0].snapshot?.providerCost?.balance == 9.25)
        #expect(snapshots[0].snapshot?.providerCost?.balanceUpdatedAt != nil)
        #expect(snapshots[0].sourceLabel == "api+web")
        #expect(snapshots[1].snapshot?.providerCost?.balance == nil)
        #expect(snapshots[1].sourceLabel == "api")
        // Unique composition owns the wallet; no provider-level duplicate remains.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
    }

    @Test
    func `multiple matching accounts are stripped and the wallet renders once at provider level`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-multi-match",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [0, 1])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.count == 2)
        #expect(snapshots.allSatisfy { $0.snapshot?.providerCost?.balance == nil })
        #expect(snapshots.allSatisfy { $0.sourceLabel == "api" })
        let publication = try #require(fixture.store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .multipleMatchingAccounts)
    }

    @Test
    func `zero matching accounts publish one unverified provider-level wallet`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-zero-match",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [])
        await fixture.store.refreshProvider(.huggingface)

        let snapshots = try #require(fixture.store.accountSnapshots[.huggingface])
        #expect(snapshots.allSatisfy { $0.snapshot?.providerCost?.balance == nil })
        let publication = try #require(fixture.store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 9.25)
        #expect(publication.attribution == .unverified)
    }

    @Test
    func `unavailable wallet attempts clear a prior provider-level publication`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-unavailable",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [],
            mode: .unavailable)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(),
            attribution: .unverified)

        await fixture.store.refreshProvider(.huggingface)

        // Attempted-and-unavailable must not keep presenting stale Credits as current.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
    }

    @Test
    func `configuration driven clearing removes the wallet even when the API fetch fails`() async throws {
        for source in [ProviderCookieSource.off, nil] {
            let fixture = try Self.makeFixture(
                suite: "hf-dual-source-config-clear-\(source.map(\.rawValue) ?? "api")",
                accountTokens: ["hf_personal_token", "hf_work_token"],
                matchingIndices: [],
                mode: .failAPI)
            fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
                balanceUSD: 42,
                observedAt: Date(),
                attribution: .unverified)
            if let source {
                fixture.settings.huggingFaceCookieSource = source
            } else {
                fixture.settings.huggingFaceUsageDataSource = .api
            }

            // The API fetch intentionally fails and its error is stored, not thrown.
            await fixture.store.refreshProvider(.huggingface)

            // Explicitly disabling the browser authority (cookies Off or isolated API mode)
            // clears the wallet regardless of the API outcome.
            #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)
        }
    }

    @Test
    func `ordinary auto API failure before wallet work preserves prior state`() async throws {
        let fixture = try Self.makeFixture(
            suite: "hf-dual-source-failure-preserves",
            accountTokens: ["hf_personal_token", "hf_work_token"],
            matchingIndices: [],
            mode: .failAPI)
        fixture.settings.huggingFaceCookieSource = .manual
        fixture.settings.huggingFaceManualCookieHeader = "session=fixture"
        let prior = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(),
            attribution: .unverified)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = prior

        // The API fetch intentionally fails and its error is stored, not thrown.
        await fixture.store.refreshProvider(.huggingface)

        // Browser use remains configured, so the failed refresh makes no wallet transition.
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == prior)
    }

    @Test
    func `cli batch post pass strips ambiguous compositions and keeps unique ones`() {
        let accountA = ProviderTokenAccount(
            id: UUID(),
            label: "A",
            token: "hf_a",
            addedAt: 0,
            lastUsed: nil)
        let accountB = ProviderTokenAccount(
            id: UUID(),
            label: "B",
            token: "hf_b",
            addedAt: 0,
            lastUsed: nil)
        let composedA = Self.batchEntry(account: accountA, composed: true)
        let composedB = Self.batchEntry(account: accountB, composed: true)

        let stripped = CodexBarCLI.reconciledHuggingFaceWalletBatch([composedA, composedB])
        #expect(stripped.count == 2)
        for entry in stripped {
            guard case let .success(result) = entry.outcome.result else {
                Issue.record("Expected a successful batch entry")
                continue
            }
            #expect(result.sourceLabel == "api")
            #expect(result.usage.providerCost?.balance == nil)
            #expect(result.huggingFaceWalletOutcome == nil)
        }

        // A unique local match survives the CLI post-pass untouched.
        let single = CodexBarCLI.reconciledHuggingFaceWalletBatch([
            composedA,
            Self.batchEntry(account: accountB, composed: false),
        ])
        guard case let .success(keptResult) = single[0].outcome.result else {
            Issue.record("Expected the unique composition to survive")
            return
        }
        #expect(keptResult.sourceLabel == "api+web")
        #expect(keptResult.usage.providerCost?.balance == 9.25)
    }

    private static func batchEntry(
        account: ProviderTokenAccount,
        composed: Bool) -> (account: ProviderTokenAccount?, outcome: ProviderFetchOutcome)
    {
        let observedAt = Date()
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Reported billing period",
            balance: composed ? 9.25 : nil,
            balanceUpdatedAt: composed ? observedAt : nil,
            updatedAt: observedAt)
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: observedAt,
            identity: nil)
        let result = ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: composed ? "api+web" : "api",
            strategyID: "huggingface.js",
            strategyKind: .apiToken,
            huggingFaceWalletOutcome: composed
                ? .localMatchComposed(balanceUSD: 9.25, observedAt: observedAt)
                : .providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: 9.25,
                    observedAt: observedAt,
                    attribution: .unverified)))
        return (account, ProviderFetchOutcome(result: .success(result), attempts: []))
    }

    private struct Fixture {
        let store: UsageStore
        let settings: SettingsStore
    }

    private static func makeFixture(
        suite: String,
        accountTokens: [String],
        matchingIndices: Set<Int>,
        mode: HuggingFaceWalletOutcomeStubStrategy.Mode = .compose([])) throws -> Fixture
    {
        let settings = testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.multiAccountMenuLayout = .stacked
        settings.huggingFaceCookieSource = .manual
        settings.huggingFaceManualCookieHeader = "session=fixture"
        for (index, token) in accountTokens.enumerated() {
            settings.addTokenAccount(provider: .huggingface, label: "Account \(index)", token: token)
        }
        let accounts = settings.tokenAccounts(for: .huggingface)
        let matchingAccountIDs = Set(accounts.indices
            .filter { matchingIndices.contains($0) }
            .compactMap { accounts[$0].id })
        let resolvedMode: HuggingFaceWalletOutcomeStubStrategy.Mode = switch mode {
        case .compose:
            .compose(matchingAccountIDs)
        case .providerLevelUnverified, .unavailable, .failAPI:
            mode
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let baseDescriptor = baseSpec.descriptor
        let stub = HuggingFaceWalletOutcomeStubStrategy(mode: resolvedMode, balanceUSD: 9.25)
        store.providerSpecs[.huggingface] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .huggingface,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api, .web],
                    pipeline: ProviderFetchPipeline { _ in [stub] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return Fixture(store: store, settings: settings)
    }
}
