import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HuggingFaceProviderHTTPTransportTests {
    @Test
    func `normalizes a complete usage event and overrides the JSON accept header`() async throws {
        let inner = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            #expect(request.timeoutInterval == HuggingFaceProviderHTTPTransport.requestTimeout)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]))
            return (Data("event: usage\ndata: {\"inference\":{}}\n\n".utf8), response)
        }
        let transport = HuggingFaceProviderHTTPTransport(transport: inner)
        let request = try Self.request(path: "/api/settings/billing/usage/live")

        let (data, response) = try await transport.data(for: request)

        #expect(data == Data(#"{"inference":{}}"#.utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test
    func `rejects an otherwise successful billing response without a complete usage event`() async throws {
        let inner = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("event: ping\ndata: {}\n\n".utf8), response)
        }
        let transport = HuggingFaceProviderHTTPTransport(transport: inner)
        let request = try Self.request(path: "/api/settings/billing/usage/live")

        do {
            _ = try await transport.data(for: request)
            Issue.record("Expected an incomplete Hugging Face usage stream to fail")
        } catch let error as ProviderPluginError {
            #expect(error.localizedDescription.contains("complete usage event"))
        }
    }

    @Test
    func `parses fragmented UTF8 comments multiline data and standard line endings`() throws {
        var parser = HuggingFaceSSEParser()
        let source = ": heartbeat\r\nevent: usage\rdata: {\"message\":\"café\",\r\ndata: \"ok\"}\r\n\r\n"
        var payload: Data?
        for byte in source.utf8 {
            payload = try parser.append(Data([byte])) ?? payload
        }

        #expect(try String(data: #require(payload), encoding: .utf8) == """
        {"message":"café",
        "ok"}
        """)
    }

    @Test
    func `rejects invalid UTF8 in a completed SSE line`() throws {
        var parser = HuggingFaceSSEParser()
        do {
            _ = try parser.append(Data([0x65, 0x76, 0x65, 0x6E, 0x74, 0x3A, 0x20, 0xC3, 0x0A]))
            Issue.record("Expected invalid UTF-8 to fail")
        } catch let error as ProviderPluginError {
            #expect(error.localizedDescription.contains("valid UTF-8"))
        }
    }

    @Test
    func `rejects requests outside the two exact official endpoints`() async throws {
        let inner = ProviderHTTPTransportHandler { _ in
            Issue.record("The rejected request reached the underlying transport")
            throw URLError(.badURL)
        }
        let transport = HuggingFaceProviderHTTPTransport(transport: inner)
        let requests = try [
            Self.request(path: "/api/users/example/billing/usage/live"),
            Self.request(path: "/api/settings/billing/usage/live", query: "x=1"),
            URLRequest(url: #require(URL(string: "http://huggingface.co/api/whoami-v2"))),
        ]

        for request in requests {
            do {
                _ = try await transport.data(for: request)
                Issue.record("Expected the request to be rejected")
            } catch let error as ProviderPluginError {
                #expect(error.localizedDescription.contains("not allowed"))
            }
        }
    }

    @Test
    func `preserves a non-success response without parsing its body`() async throws {
        let inner = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(#"{"error":"rejected"}"#.utf8), response)
        }
        let transport = HuggingFaceProviderHTTPTransport(transport: inner)
        let request = try Self.request(path: "/api/settings/billing/usage/live")

        let (data, response) = try await transport.data(for: request)

        #expect(data.isEmpty)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test
    func `rejects an oversized buffered response`() async throws {
        let inner = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(repeating: 0x61, count: HuggingFaceProviderHTTPTransport.maximumResponseBytes + 1), response)
        }
        let transport = HuggingFaceProviderHTTPTransport(transport: inner)
        let request = try Self.request(path: "/api/settings/billing/usage/live")

        do {
            _ = try await transport.data(for: request)
            Issue.record("Expected an oversized response to fail")
        } catch let error as ProviderPluginError {
            #expect(error.localizedDescription.contains("1048576-byte limit"))
        }
    }

    private static func request(path: String, query: String? = nil) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = path
        components.query = query
        let url = try #require(components.url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

#if canImport(Darwin)
@Suite(.serialized)
struct HuggingFaceProviderURLSessionTransportTests {
    @Test
    func `returns after a complete usage event and cancels the still-open connection`() async throws {
        let probe = HuggingFaceStreamingProbe()
        let body = Data("event: usage\r\ndata: {\"inference\":{}}\r\n\r\n".utf8)
        let transport = Self.transport(
            plan: HuggingFaceStreamingPlan(
                chunks: [Data(body.prefix(9)), Data(body.dropFirst(9))],
                finishes: false),
            probe: probe)

        let result = try await Self.fetch(transport: transport)

        #expect(result.data == Data(#"{"inference":{}}"#.utf8))
        #expect(result.statusCode == 200)
        #expect(probe.requests.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(probe.waitForStop())
    }

    @Test
    func `cancels an open stream when the caller task is cancelled`() async throws {
        let probe = HuggingFaceStreamingProbe()
        let transport = Self.transport(
            plan: HuggingFaceStreamingPlan(
                chunks: [Data("event: usage\ndata: {}\n".utf8)],
                finishes: false),
            probe: probe)
        let request = try Self.request()
        let task = Task { try await transport.data(for: request) }

        #expect(probe.waitForStart())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation of an open Hugging Face stream to fail")
        } catch {
            // The URLSession cancellation is expected to surface as a transport error.
        }
        #expect(probe.waitForStop())
    }

    @Test
    func `rejects an oversized streaming response and cancels the connection`() async throws {
        let probe = HuggingFaceStreamingProbe()
        let transport = Self.transport(
            plan: HuggingFaceStreamingPlan(
                chunks: [Data(repeating: 0x61, count: HuggingFaceProviderHTTPTransport.maximumResponseBytes + 1)],
                finishes: false),
            probe: probe)

        do {
            _ = try await Self.fetch(transport: transport)
            Issue.record("Expected an oversized Hugging Face stream to fail")
        } catch let error as ProviderPluginError {
            #expect(error.localizedDescription.contains("1048576-byte limit"))
        }
        #expect(probe.waitForStop())
    }

    @Test
    func `rejects a redirect before following it`() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let transport = HuggingFaceProviderHTTPTransport(configuration: configuration)
        let session = URLSession(configuration: .ephemeral)
        let request = try Self.request()
        let redirectURL = try #require(URL(string: "https://huggingface.co/redirected"))
        let redirectRequest = URLRequest(url: redirectURL)
        let requestURL = try #require(request.url)
        let redirectResponse = try #require(HTTPURLResponse(
            url: requestURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]))
        let result = LockIsolated<URLRequest?>(redirectRequest)

        transport.urlSession(
            session,
            task: session.dataTask(with: request),
            willPerformHTTPRedirection: redirectResponse,
            newRequest: redirectRequest)
        { redirectedRequest in
            result.setValue(redirectedRequest)
        }

        #expect(result.value == nil)
    }

    private static func transport(
        plan: HuggingFaceStreamingPlan,
        probe: HuggingFaceStreamingProbe) -> HuggingFaceProviderHTTPTransport
    {
        HuggingFaceStreamingStubURLProtocol.install(plan: plan, probe: probe)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HuggingFaceStreamingStubURLProtocol.self]
        return HuggingFaceProviderHTTPTransport(configuration: configuration)
    }

    private static func request() throws -> URLRequest {
        var request =
            try URLRequest(url: #require(URL(string: "https://huggingface.co/api/settings/billing/usage/live")))
        request.httpMethod = "GET"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func fetch(transport: HuggingFaceProviderHTTPTransport) async throws -> TransportResult {
        try await withThrowingTaskGroup(of: TransportResult.self) { group in
            group.addTask {
                let request = try Self.request()
                let (data, response) = try await transport.data(for: request)
                let httpResponse = try #require(response as? HTTPURLResponse)
                return TransportResult(data: data, statusCode: httpResponse.statusCode)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw HuggingFaceTransportTimeout()
            }
            defer { group.cancelAll() }
            return try await #require(group.next())
        }
    }
}

private struct TransportResult: Sendable {
    let data: Data
    let statusCode: Int
}

private struct HuggingFaceTransportTimeout: Error {}

private struct HuggingFaceStreamingPlan: Sendable {
    let statusCode: Int
    let chunks: [Data]
    let finishes: Bool

    init(statusCode: Int = 200, chunks: [Data], finishes: Bool) {
        self.statusCode = statusCode
        self.chunks = chunks
        self.finishes = finishes
    }
}

private final class HuggingFaceStreamingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let startSemaphore = DispatchSemaphore(value: 0)
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private(set) var requests: [URLRequest] = []

    func recordStart(request: URLRequest) {
        self.lock.withLock {
            self.requests.append(request)
        }
        self.startSemaphore.signal()
    }

    func recordStop() {
        self.stopSemaphore.signal()
    }

    func waitForStart() -> Bool {
        self.startSemaphore.wait(timeout: .now() + 1) == .success
    }

    func waitForStop() -> Bool {
        self.stopSemaphore.wait(timeout: .now() + 1) == .success
    }
}

private class HuggingFaceStreamingStubURLProtocol: URLProtocol {
    private static let planBox = LockIsolated<HuggingFaceStreamingPlan?>(nil)
    private static let probeBox = LockIsolated<HuggingFaceStreamingProbe?>(nil)

    static func install(plan: HuggingFaceStreamingPlan, probe: HuggingFaceStreamingProbe) {
        self.planBox.setValue(plan)
        self.probeBox.setValue(probe)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == "huggingface.co"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.probeBox.value?.recordStart(request: self.request)
        guard let plan = Self.planBox.value, let requestURL = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: plan.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks {
            self.client?.urlProtocol(self, didLoad: chunk)
        }
        if plan.finishes {
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.probeBox.value?.recordStop()
    }
}
#endif
