import Foundation

public enum HuggingFaceSettingsReader {
    public static let tokenEnvironmentKey = "HF_TOKEN"

    public static func token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.tokenEnvironmentKey])
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum HuggingFaceSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Hugging Face user access token not configured. Set HF_TOKEN environment variable or configure in Settings."
        }
    }
}
