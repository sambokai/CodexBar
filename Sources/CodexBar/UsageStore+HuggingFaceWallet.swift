import CodexBarCore
import Foundation

// Provider-specific by design: Hugging Face's browser-session prepaid wallet is one provider-level
// value. These helpers own its deterministic publication, configuration-driven clearing, and the
// stacked-batch attribution post-pass. The wallet is never cached as a token-account snapshot.

extension UsageStore {
    func applyHuggingFaceWalletOutcome(provider: UsageProvider, result: ProviderFetchResult) {
        // Provider-specific by design: Hugging Face publishes one provider-level browser wallet.
        guard provider == .huggingface else { return }
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
        }
    }

    /// Provider-specific by design (FP-194): a per-account Hugging Face Auto fetch can only prove a
    /// *local* bearer/browser identity match. This batch post-pass determines global uniqueness:
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
        let composedResults = results.filter { result in
            guard case let .success(fetchResult) = result.outcome.result else { return false }
            return fetchResult.huggingFaceWalletOutcome?.isLocalMatchComposed == true
        }

        var rewritten = results
        if composedResults.count > 1 {
            // Ambiguous attribution: no account card may own the wallet. Strip every provisional
            // composition so the single browser value renders once at provider level.
            rewritten = results.map { result in
                guard case let .success(fetchResult) = result.outcome.result,
                      fetchResult.huggingFaceWalletOutcome?.isLocalMatchComposed == true
                else { return result }
                let strippedOutcome = fetchResult
                    .replacingUsage(Self.strippingHuggingFaceWalletBalance(from: fetchResult.usage))
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

        // Provider-specific by design: Hugging Face publishes the wallet once at provider level.
        if composedResults.count == 1 {
            self.huggingFaceBrowserWallets[.huggingface] = nil
        } else if composedResults.count > 1 {
            let wallet = composedResults.lazy.compactMap { result -> HuggingFaceWalletSnapshot? in
                guard case let .success(fetchResult) = result.outcome.result else { return nil }
                return fetchResult.huggingFaceWalletOutcome?.composedWallet
            }.first
            if let wallet {
                self.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
                    balanceUSD: wallet.balanceUSD,
                    observedAt: wallet.observedAt,
                    attribution: .multipleMatchingAccounts)
            }
        } else if let observation = results.compactMap({ result -> HuggingFaceBrowserWalletPublication? in
            guard case let .success(fetchResult) = result.outcome.result else { return nil }
            return fetchResult.huggingFaceWalletOutcome?.providerLevelPublication
        }).first {
            self.huggingFaceBrowserWallets[.huggingface] = observation
        } else if results.contains(where: { result in
            guard case let .success(fetchResult) = result.outcome.result else { return false }
            switch fetchResult.huggingFaceWalletOutcome {
            case .unavailable, .notAttempted: return true
            default: return false
            }
        }) {
            self.huggingFaceBrowserWallets[.huggingface] = nil
        }
        return rewritten
    }

    private static func strippingHuggingFaceWalletBalance(from usage: UsageSnapshot) -> UsageSnapshot {
        guard let cost = usage.providerCost, cost.balance != nil else { return usage }
        let strippedCost = ProviderCostSnapshot(
            used: cost.used,
            limit: cost.limit,
            currencyCode: cost.currencyCode,
            period: cost.period,
            resetsAt: cost.resetsAt,
            nextRegenAmount: cost.nextRegenAmount,
            personalUsed: cost.personalUsed,
            balance: nil,
            balanceUpdatedAt: nil,
            updatedAt: cost.updatedAt)
        return usage.with(providerCost: strippedCost)
    }
}
