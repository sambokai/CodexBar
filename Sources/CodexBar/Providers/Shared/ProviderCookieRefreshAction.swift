import CodexBarCore
import Foundation

@MainActor
enum ProviderCookieRefreshAction {
    enum Outcome: Equatable {
        case refreshed
        case failed
    }

    enum ResultValidation {
        case webSource
        case providerCostBalance
    }

    @TaskLocal static var isRefreshingCookie = false

    static func descriptor(
        provider: UsageProvider,
        cookieSource: @escaping () -> ProviderCookieSource,
        additionalVisibility: @escaping () -> Bool = { true },
        resultValidation: ResultValidation = .webSource,
        context: ProviderSettingsContext) -> ProviderSettingsActionDescriptor
    {
        ProviderSettingsActionDescriptor(
            id: "\(provider.rawValue)-reimport-cookie",
            title: "Refresh",
            style: .bordered,
            isVisible: { cookieSource() == .auto && additionalVisibility() },
            perform: {
                await ProviderSettingsRefreshInteraction.perform {
                    await self.perform(
                        provider: provider,
                        resultValidation: resultValidation,
                        context: context)
                }
            })
    }

    static func trailingText(
        provider: UsageProvider,
        cookieSource: ProviderCookieSource,
        context: ProviderSettingsContext) -> String?
    {
        guard cookieSource != .manual else { return nil }
        return context.statusText(self.statusID(provider)) ?? ProviderCookieSourceUI
            .cachedTrailingText(provider: provider)
    }

    static func refresh(
        provider: UsageProvider,
        operation: () async -> Bool) async -> Outcome
    {
        await self.$isRefreshingCookie.withValue(true) {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                guard let gate = CookieHeaderCache.beginRefreshReadSuppression(provider: provider) else {
                    return .failed
                }
                defer { CookieHeaderCache.endRefreshReadSuppression(gate) }

                let validated = await operation()
                guard validated, !Task.isCancelled else { return .failed }

                let commit = CookieHeaderCache.commitRefreshReadSuppression(gate)
                guard commit.stagedCount > 0,
                      commit.committedCount == commit.stagedCount,
                      commit.failedCount == 0
                else { return .failed }
                return .refreshed
            }
        }
    }

    private static func perform(
        provider: UsageProvider,
        resultValidation: ResultValidation,
        context: ProviderSettingsContext) async
    {
        context.setStatusText(self.statusID(provider), L("Refreshing"))
        let previousUpdatedAt = context.store.snapshot(for: provider.instanceID)?.updatedAt
        let outcome = await self.refresh(provider: provider) {
            await context.store.refreshProvider(provider, allowDisabled: true)
            return self.resultIsValid(
                provider: provider,
                validation: resultValidation,
                previousUpdatedAt: previousUpdatedAt,
                context: context)
        }
        context.setStatusText(self.statusID(provider), outcome == .refreshed ? nil : L("Failed"))
    }

    private static func resultIsValid(
        provider: UsageProvider,
        validation: ResultValidation,
        previousUpdatedAt: Date?,
        context: ProviderSettingsContext) -> Bool
    {
        guard context.store.error(for: provider) == nil,
              let snapshot = context.store.snapshot(for: provider.instanceID),
              previousUpdatedAt.map({ snapshot.updatedAt != $0 }) ?? true
        else { return false }

        switch validation {
        case .webSource:
            return context.store.lastSourceLabels[provider.instanceID] == "web"
        case .providerCostBalance:
            return snapshot.providerCost?.balance != nil
        }
    }

    private static func statusID(_ provider: UsageProvider) -> String {
        "\(provider.rawValue)-cookie-refresh-status"
    }
}
