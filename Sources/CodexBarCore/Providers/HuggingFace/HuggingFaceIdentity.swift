import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of an authenticated `whoami-v2` probe.
///
/// `opaqueUserID` is the matching-layer correlation key from FP-193/FP-194. It must stay transient:
/// never persist it into snapshots or history, never log it, and never display it. Only the display
/// fields are projected into `ProviderIdentitySnapshot`.
public struct HuggingFaceIdentity: Equatable, Sendable {
    public let opaqueUserID: String
    public let accountID: String?
    public let email: String?
    public let isPro: Bool

    /// Display-only projection for `UsageSnapshot.identity`. Drops the opaque matching ID and
    /// mirrors the display mapping the former plugin-owned identity provided.
    public func displayIdentitySnapshot(provider: UsageProvider) -> ProviderIdentitySnapshot? {
        guard self.accountID != nil || self.email != nil || self.isPro else { return nil }
        return ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: self.email,
            accountOrganization: nil,
            loginMethod: self.isPro ? "PRO" : nil,
            accountID: self.accountID)
    }
}

/// Provider-private owner of `GET https://huggingface.co/api/whoami-v2`.
///
/// Successful identities are cached in memory for 12 hours keyed by a one-way credential
/// fingerprint (`CookieHeaderCache.credentialFingerprint`), never by the raw token or cookie
/// header. Failures are not cached so a transient identity outage retries on the next refresh.
/// Cancellation always propagates; every other failure resolves to `nil` ("identity
/// unavailable") because billing never depends on identity.
public actor HuggingFaceIdentityService {
    static let cacheTTLSeconds: TimeInterval = 12 * 60 * 60

    public static let shared = HuggingFaceIdentityService()

    struct CacheEntry: Sendable {
        let identity: HuggingFaceIdentity
        let expiresAt: Date
    }

    private let transport: any ProviderHTTPTransport
    var cache: [String: CacheEntry] = [:]

    public init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    public static let whoamiURL = URL(string: "https://huggingface.co/api/whoami-v2")!

    public func identity(
        bearerToken: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        try await self.identity(
            cacheKeyPrefix: "bearer:",
            credential: bearerToken,
            headerField: "Authorization",
            headerValue: "Bearer \(bearerToken)",
            timeout: timeout)
    }

    public func identity(
        cookieHeader: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        try await self.identity(
            cacheKeyPrefix: "cookie:",
            credential: cookieHeader,
            headerField: "Cookie",
            headerValue: cookieHeader,
            timeout: timeout)
    }

    private func identity(
        cacheKeyPrefix: String,
        credential: String,
        headerField: String,
        headerValue: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCredential.isEmpty else { return nil }
        let cacheKey = cacheKeyPrefix + CookieHeaderCache.credentialFingerprint(trimmedCredential)
        if let entry = self.cache[cacheKey], entry.expiresAt > Date() {
            return entry.identity
        }

        let identity: HuggingFaceIdentity?
        do {
            identity = try await self.requestIdentity(
                headerField: headerField,
                headerValue: headerValue,
                timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Identity lookup never blocks billing: ordinary HTTP/auth/parse/network failures
            // resolve to "identity unavailable".
            return nil
        }
        guard let identity else { return nil }
        self.cache[cacheKey] = CacheEntry(
            identity: identity,
            expiresAt: Date().addingTimeInterval(Self.cacheTTLSeconds))
        return identity
    }

    private func requestIdentity(
        headerField: String,
        headerValue: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        var request = URLRequest(url: Self.whoamiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.1, timeout)
        request.setValue(headerValue, forHTTPHeaderField: headerField)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await self.transport.response(for: request)
        guard response.statusCode == 200 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: response.data),
              let payload = object as? [String: Any]
        else { return nil }
        return Self.parseIdentity(payload)
    }

    static func parseIdentity(_ payload: [String: Any]) -> HuggingFaceIdentity? {
        guard payload["type"] as? String == "user" else { return nil }
        guard let opaqueUserID = nonEmptyString(payload["id"]) else { return nil }
        let accountID = Self.nonEmptyString(payload["name"])
        let email = Self.nonEmptyString(payload["email"])
        let isPro = payload["isPro"] as? Bool == true
        return HuggingFaceIdentity(
            opaqueUserID: opaqueUserID,
            accountID: accountID,
            email: email,
            isPro: isPro)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
