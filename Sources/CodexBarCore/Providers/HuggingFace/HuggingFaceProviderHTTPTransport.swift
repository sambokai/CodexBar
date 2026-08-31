import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HuggingFaceProviderHTTPTransport: NSObject, ProviderHTTPTransport, URLSessionDataDelegate,
    @unchecked Sendable
{
    static let requestTimeout: TimeInterval = 8
    static let maximumResponseBytes = 1024 * 1024

    private enum Endpoint: Equatable {
        case identity
        case billing
    }

    private struct RequestState {
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let endpoint: Endpoint
        var response: HTTPURLResponse?
        var data = Data()
        var parser = HuggingFaceSSEParser()
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func set(_ task: URLSessionDataTask) {
            let cancel = self.lock.withLock {
                self.task = task
                return self.cancelled
            }
            if cancel { task.cancel() }
        }

        func cancel() {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private let transport: (any ProviderHTTPTransport)?
    private let sessionConfiguration: URLSessionConfiguration?
    private lazy var session: URLSession = {
        guard let configuration = self.sessionConfiguration else {
            preconditionFailure("Hugging Face transport session is unavailable")
        }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]

    override init() {
        self.transport = nil
        self.sessionConfiguration = Self.defaultConfiguration()
        super.init()
    }

    init(transport: any ProviderHTTPTransport) {
        self.transport = transport
        self.sessionConfiguration = nil
        super.init()
    }

    init(configuration: URLSessionConfiguration) {
        self.transport = nil
        self.sessionConfiguration = Self.prepareConfiguration(configuration)
        super.init()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (prepared, endpoint) = try Self.prepare(request)
        if let transport = self.transport {
            let (data, response) = try await transport.data(for: prepared)
            return try Self.normalized(data: data, response: response, endpoint: endpoint)
        }
        return try await self.data(for: prepared, endpoint: endpoint, session: self.session)
    }

    private func data(
        for request: URLRequest,
        endpoint: Endpoint,
        session: URLSession) async throws -> (Data, URLResponse)
    {
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                (Data, URLResponse), Error,
            >) in
                let task = session.dataTask(with: request)
                self.lock.withLock {
                    self.states[task.taskIdentifier] = RequestState(
                        continuation: continuation,
                        endpoint: endpoint)
                }
                taskBox.set(task)
                task.resume()
            }
        }, onCancel: {
            taskBox.cancel()
        })
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return configuration
    }

    private static func prepareConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = self.requestTimeout
        configuration.timeoutIntervalForResource = self.requestTimeout
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return configuration
    }

    private static func prepare(_ request: URLRequest) throws -> (URLRequest, Endpoint) {
        guard request.httpMethod?.uppercased() == "GET",
              let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "huggingface.co",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            throw ProviderPluginError.networkPolicy("Hugging Face request URL is not allowed")
        }

        let endpoint: Endpoint
        guard let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            throw ProviderPluginError.networkPolicy("Hugging Face request URL is not allowed")
        }
        switch encodedPath {
        case "/api/whoami-v2":
            endpoint = .identity
        case "/api/settings/billing/usage/live":
            endpoint = .billing
        default:
            throw ProviderPluginError.networkPolicy("Hugging Face request URL is not allowed")
        }

        var prepared = request
        prepared.timeoutInterval = Self.requestTimeout
        prepared.setValue(
            endpoint == .billing ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept")
        return (prepared, endpoint)
    }

    private static func normalized(
        data: Data,
        response: URLResponse,
        endpoint: Endpoint) throws -> (Data, URLResponse)
    {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderPluginError.http("Hugging Face returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            return (Data(), response)
        }
        guard data.count <= self.maximumResponseBytes else {
            throw ProviderPluginError.http("Hugging Face response exceeded the 1048576-byte limit")
        }
        guard endpoint == .billing else { return (data, response) }

        var parser = HuggingFaceSSEParser()
        if let payload = try parser.append(data) {
            return (payload, response)
        }
        throw ProviderPluginError.http("Hugging Face billing stream ended before a complete usage event")
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        guard let httpResponse = response as? HTTPURLResponse else {
            self.finish(
                taskIdentifier: dataTask.taskIdentifier,
                result: .failure(ProviderPluginError.http("Hugging Face returned a non-HTTP response")),
                cancel: dataTask)
            completionHandler(.cancel)
            return
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            self.finish(
                taskIdentifier: dataTask.taskIdentifier,
                result: .success((Data(), httpResponse)),
                cancel: dataTask)
        } else {
            self.lock.withLock {
                self.states[dataTask.taskIdentifier]?.response = httpResponse
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var result: Result<(Data, URLResponse), Error>?

        self.lock.lock()
        if var state = self.states[dataTask.taskIdentifier] {
            if state.data.count + data.count > Self.maximumResponseBytes {
                self.states.removeValue(forKey: dataTask.taskIdentifier)
                continuation = state.continuation
                result = .failure(ProviderPluginError.http(
                    "Hugging Face response exceeded the 1048576-byte limit"))
            } else {
                state.data.append(data)
                do {
                    if state.endpoint == .billing,
                       let payload = try state.parser.append(data),
                       let response = state.response
                    {
                        self.states.removeValue(forKey: dataTask.taskIdentifier)
                        continuation = state.continuation
                        result = .success((payload, response))
                    } else {
                        self.states[dataTask.taskIdentifier] = state
                    }
                } catch {
                    self.states.removeValue(forKey: dataTask.taskIdentifier)
                    continuation = state.continuation
                    result = .failure(error)
                }
            }
        }
        self.lock.unlock()

        if let continuation, let result {
            dataTask.cancel()
            continuation.resume(with: result)
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = self.lock.withLock({ self.states.removeValue(forKey: task.taskIdentifier) }) else {
            return
        }
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            if state.endpoint == .billing {
                state.continuation.resume(throwing: ProviderPluginError.http(
                    "Hugging Face billing stream ended before a complete usage event"))
            } else {
                state.continuation.resume(returning: (state.data, response))
            }
        } else {
            state.continuation.resume(throwing: ProviderPluginError.http(
                "Hugging Face returned no HTTP response"))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        #if canImport(Darwin)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        #else
        _ = challenge
        completionHandler(.performDefaultHandling, nil)
        #endif
    }

    private func finish(
        taskIdentifier: Int,
        result: Result<(Data, URLResponse), Error>,
        cancel task: URLSessionTask)
    {
        let continuation = self.lock.withLock {
            self.states.removeValue(forKey: taskIdentifier)?.continuation
        }
        task.cancel()
        continuation?.resume(with: result)
    }
}

struct HuggingFaceSSEParser: Sendable {
    private var line = Data()
    private var pendingCR = false
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(_ data: Data) throws -> Data? {
        for byte in data {
            if self.pendingCR {
                self.pendingCR = false
                if byte == 0x0A { continue }
            }

            switch byte {
            case 0x0D:
                if let payload = try self.processLine() { return payload }
                self.pendingCR = true
            case 0x0A:
                if let payload = try self.processLine() { return payload }
            default:
                self.line.append(byte)
            }
        }
        return nil
    }

    private mutating func processLine() throws -> Data? {
        guard let text = String(data: self.line, encoding: .utf8) else {
            throw ProviderPluginError.http("Hugging Face billing stream was not valid UTF-8")
        }
        self.line.removeAll(keepingCapacity: true)

        guard !text.isEmpty else {
            let payload: Data? = if self.eventName == "usage", !self.dataLines.isEmpty {
                Data(self.dataLines.joined(separator: "\n").utf8)
            } else {
                nil
            }
            self.eventName = nil
            self.dataLines.removeAll(keepingCapacity: true)
            return payload
        }

        if text.hasPrefix(":") { return nil }
        let separator = text.firstIndex(of: ":")
        let field = separator.map { String(text[..<$0]) } ?? text
        var value = separator.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }

        switch field {
        case "event":
            self.eventName = value
        case "data":
            self.dataLines.append(value)
        default:
            break
        }
        return nil
    }
}
