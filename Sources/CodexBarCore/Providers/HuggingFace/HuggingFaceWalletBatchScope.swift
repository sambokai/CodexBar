import Foundation

/// A fresh prepaid-wallet observation parsed from the authenticated billing page.
public struct HuggingFaceWalletSnapshot: Equatable, Sendable {
    public let balanceUSD: Double
    public let observedAt: Date

    public init(balanceUSD: Double, observedAt: Date) {
        self.balanceUSD = balanceUSD
        self.observedAt = observedAt
    }
}

/// One browser wallet observation plus the browser-session identity resolved from the same
/// normalized cookie during the same batch. `identity` is matching-layer data only: it never
/// reaches snapshots, history, logs, or UI.
public struct HuggingFaceBrowserWalletObservation: Equatable, Sendable {
    public let wallet: HuggingFaceWalletSnapshot
    let identity: HuggingFaceIdentity?
}

/// Store-level attribution for a provider-level browser wallet that is not composed into an
/// account snapshot.
public enum HuggingFaceWalletAttribution: Equatable, Sendable {
    /// Browser identity is missing, malformed, or does not match the compared API identity.
    case unverified
    /// More than one token account in the batch matched the browser identity, so no single
    /// account card can own the wallet.
    case multipleMatchingAccounts
}

/// Provider-level browser wallet value surfaced outside any token-account snapshot.
public struct HuggingFaceBrowserWalletPublication: Equatable, Sendable {
    public let balanceUSD: Double
    public let observedAt: Date
    public let attribution: HuggingFaceWalletAttribution

    public init(balanceUSD: Double, observedAt: Date, attribution: HuggingFaceWalletAttribution) {
        self.balanceUSD = balanceUSD
        self.observedAt = observedAt
        self.attribution = attribution
    }
}

/// Transient per-refresh wallet outcome carried on Hugging Face fetch results.
///
/// A per-account Auto fetch can only establish a *local* bearer/browser identity match, so a
/// composed result is provisional in stacked batches: the batch post-pass decides global
/// uniqueness. The strategy never claims "exactly one matching account".
public enum HuggingFaceBrowserWalletOutcome: Equatable, Sendable {
    /// This fetch's bearer identity exactly matched the browser identity and the API snapshot
    /// carries the composed wallet balance.
    case localMatchComposed(balanceUSD: Double, observedAt: Date)
    /// The wallet was observed but must not compose into this account's snapshot.
    case providerLevel(HuggingFaceBrowserWalletPublication)
    /// Browser-wallet work was attempted and failed. Provider-level wallet state must clear.
    case unavailable
    /// No browser-wallet attempt was made (cookies Off, unusable manual header, explicit API mode).
    case notAttempted

    public var isLocalMatchComposed: Bool {
        if case .localMatchComposed = self { return true }
        return false
    }

    public var composedWallet: HuggingFaceWalletSnapshot? {
        if case let .localMatchComposed(balanceUSD, observedAt) = self {
            return HuggingFaceWalletSnapshot(balanceUSD: balanceUSD, observedAt: observedAt)
        }
        return nil
    }

    public var providerLevelPublication: HuggingFaceBrowserWalletPublication? {
        if case let .providerLevel(publication) = self { return publication }
        return nil
    }

    public var makesDeterministicClearingTransition: Bool {
        switch self {
        case .unavailable, .notAttempted: true
        case .localMatchComposed, .providerLevel: false
        }
    }
}

/// Shared browser-wallet eligibility policy used by Auto fetching and the store's
/// configuration-driven reconciliation. Wallet work happens only when a browser authority is
/// configured and usable.
public enum HuggingFaceBrowserWalletPolicy {
    public static func isWalletEligible(_ context: ProviderFetchContext) -> Bool {
        let source = context.settings?.huggingface?.cookieSource ?? .auto
        guard source != .off else { return false }
        if source == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.huggingface?.manualCookieHeader) != nil
        }
        return true
    }
}

/// Presentation helpers for the provider-level browser wallet that is not composed into an
/// account snapshot.
public enum HuggingFaceWalletPresentation {
    /// One authority-labeled detail section describing the browser-session wallet. The labels
    /// make the authority explicit and never imply the wallet belongs to a shown API account.
    public static func detailSection(
        _ publication: HuggingFaceBrowserWalletPublication) -> ProviderDetailSection?
    {
        let balance = UsageFormatter.currencyString(publication.balanceUSD, currencyCode: "USD")
        let attribution = switch publication.attribution {
        case .unverified:
            "Unverified against this API token"
        case .multipleMatchingAccounts:
            "Matches multiple API token accounts"
        }
        guard let balanceRow = try? ProviderDetailSection.Row(label: "Prepaid credits", value: balance),
              let attributionRow = try? ProviderDetailSection.Row(label: "Account", value: attribution)
        else { return nil }
        return try? ProviderDetailSection(title: "Browser session wallet", rows: [balanceRow, attributionRow])
    }
}

/// Memoizes exactly one browser-wallet observation per refresh batch.
///
/// Stacked token-account fan-out and multi-account CLI runs share one scope so N token accounts
/// cause at most one billing-page request and one browser `whoami-v2` probe. The memoized value
/// is a fresh observation for the refresh, not a long-lived balance cache, and the scope holds
/// no credential data: the cookie header is used transiently inside the fetch closure and the
/// memoized result contains only balance, timestamp, and matching-layer identity.
public actor HuggingFaceWalletBatchScope {
    public typealias ObservationFetcher = @Sendable (ProviderFetchContext) async throws ->
        HuggingFaceBrowserWalletObservation

    private var fetcher: ObservationFetcher?
    private var memo: Result<HuggingFaceBrowserWalletObservation, any Error>?

    public init() {}

    /// Returns the batch's single wallet observation, fetching it once. Whichever strategy
    /// arrives first registers its fetcher; within a batch every account uses an identically
    /// configured strategy, so the registration order is behaviorally irrelevant.
    public func observation(
        for context: ProviderFetchContext,
        fetcher: @escaping ObservationFetcher) async throws -> HuggingFaceBrowserWalletObservation
    {
        if self.fetcher == nil {
            self.fetcher = fetcher
        }
        if let memo = self.memo {
            return try memo.get()
        }
        do {
            let observation = try await self.fetcher!(context)
            self.memo = .success(observation)
            return observation
        } catch {
            self.memo = .failure(error)
            throw error
        }
    }
}
