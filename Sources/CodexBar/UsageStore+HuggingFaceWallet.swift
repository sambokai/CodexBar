import CodexBarCore
import Foundation

// Provider-specific by design: Hugging Face's browser-session prepaid wallet is one provider-level
// value. These helpers own its deterministic publication, configuration-driven clearing, and the
// stacked-batch attribution post-pass. The wallet is never cached as a token-account snapshot.

extension UsageStore {
    func applyHuggingFaceWalletOutcome(provider: UsageProvider, result: ProviderFetchResult) {
        // Provider-specific by design: Hugging Face publishes one provider-level browser wallet.
        guard provider == .huggingface else { return }
        // Web-kind success (explicit Web mode and cookie-only Auto): the fresh browser snapshot
        // itself owns the visible wallet. Clear the prior provider-level auxiliary publication and
        // record the observed wallet so a later failed Auto/API refresh cannot hide the validated
        // Credits behind a wallet-less cached account snapshot.
        if result.strategyKind == .web, let balance = result.usage.providerCost?.balance {
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
            self.huggingFaceWebOwnedWallets[provider.instanceID] = HuggingFaceWalletSnapshot(
                balanceUSD: balance,
                observedAt: result.usage.providerCost?.balanceUpdatedAt ?? result.usage.updatedAt)
            return
        }
        // API-kind success: every non-failure outcome supersedes any recorded Web-owned wallet.
        self.huggingFaceWebOwnedWallets[provider.instanceID] = nil
        // Deterministic publication rules for the provider-level browser wallet:
        // composed → clear (the wallet lives on the matching account card);
        // observed → publish fresh; unavailable/notAttempted → clear. A nil outcome (API failure
        // before wallet work) makes no transition.
        switch result.huggingFaceWalletOutcome {
        case .localMatchComposed, .unavailable, .notAttempted:
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
        case let .providerLevel(publication):
            self.huggingFaceBrowserWallets[provider.instanceID] = publication
        case nil:
            break
        }
    }

    /// Configuration-driven wallet clearing runs before fetch dispatch so disabling the browser
    /// authority or selecting isolated API mode removes any provider-level wallet even when the
    /// subsequent API request fails.
    func reconcileHuggingFaceWalletEligibility(provider: UsageProvider, context: ProviderFetchContext) {
        // Provider-specific by design: Hugging Face clears its provider-level browser wallet when
        // configuration makes the browser authority ineligible.
        guard provider == .huggingface else { return }
        if !HuggingFaceBrowserWalletPolicy.isWalletEligible(context) || context.sourceMode == .api {
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
            self.huggingFaceWebOwnedWallets[provider.instanceID] = nil
        }
    }

    /// Provider-specific by design (FP-194): a per-account Hugging Face Auto fetch can only prove a
    /// *local* bearer/browser identity match. This batch post-pass applies the shared batch-
    /// authoritative decision (`HuggingFaceWalletBatchReconciliation`) exactly once:
    ///
    /// * exactly one composed account → keep that composition, clear provider-level wallet state;
    /// * more than one composed account → strip the wallet from every account snapshot and publish
    ///   one provider-level wallet with `.multipleMatchingAccounts` attribution;
    /// * zero composed accounts → publish the fresh `.unverified` observation when one exists,
    ///   clear on attempted-and-unavailable or not-attempted outcomes, and make no transition when
    ///   every fetch failed before wallet work (no outcome payload).
    func reconcileHuggingFaceWalletAttribution(
        _ results: [TokenAccountFetchResult]) -> [TokenAccountFetchResult]
    {
        // Provider-specific by design: Hugging Face's wallet is one provider-level browser value.
        let walletOutcomes = results.map { result -> HuggingFaceBrowserWalletOutcome? in
            guard case let .success(fetchResult) = result.outcome.result else { return nil }
            return fetchResult.huggingFaceWalletOutcome
        }
        let reconciled = HuggingFaceWalletBatchReconciliation.reconcile(walletOutcomes)

        var rewritten = results
        if reconciled.stripsCompositions {
            // Ambiguous attribution: no account card may own the wallet. Strip every provisional
            // composition so the single browser value renders once at provider level.
            rewritten = results.map { result in
                guard case let .success(fetchResult) = result.outcome.result,
                      fetchResult.huggingFaceWalletOutcome?.isLocalMatchComposed == true
                else { return result }
                let strippedOutcome = fetchResult
                    .replacingUsage(HuggingFaceWalletBatchReconciliation.strippingWalletBalance(
                        from: fetchResult.usage))
                    .replacingSourceLabel("api")
                    .replacingWalletOutcome(nil)
                return TokenAccountFetchResult(
                    index: result.index,
                    account: result.account,
                    outcome: ProviderFetchOutcome(
                        result: .success(strippedOutcome),
                        attempts: result.outcome.attempts))
            }
        }

        // Apply the batch-authoritative publication decision. Every superseding decision also
        // clears the recorded Web-owned wallet; only failure transitions preserve it.
        switch reconciled.decision {
        case .composedOnAccount, .clear:
            self.huggingFaceBrowserWallets[.huggingface] = nil
            self.huggingFaceWebOwnedWallets[.huggingface] = nil
        case let .providerLevel(publication):
            self.huggingFaceBrowserWallets[.huggingface] = publication
            self.huggingFaceWebOwnedWallets[.huggingface] = nil
        case .noTransition:
            break
        }
        return rewritten
    }

    /// Provider-specific by design (FP-194): a failed Auto/API refresh makes no wallet transition
    /// of its own, but it can replace the visible Web snapshot with a wallet-less cached account
    /// snapshot. When a validated browser wallet was published by a successful Web-kind refresh,
    /// keep it visible once at provider level with `.webSession` attribution until the next
    /// successful refresh supersedes it.
    func reconcileHuggingFaceWalletAfterFetchFailure(provider: UsageProvider, error: any Error) {
        // Provider-specific by design: Hugging Face is the only provider whose browser wallet can
        // outlive a failed refresh through this recovery publication.
        guard provider == .huggingface else { return }
        guard !Self.errorIsCancellation(error) else { return }
        guard let wallet = self.huggingFaceWebOwnedWallets[provider.instanceID] else { return }
        self.huggingFaceBrowserWallets[provider.instanceID] = HuggingFaceBrowserWalletPublication(
            balanceUSD: wallet.balanceUSD,
            observedAt: wallet.observedAt,
            attribution: .webSession)
    }
}
