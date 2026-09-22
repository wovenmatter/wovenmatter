import Foundation

public enum ProviderConnectionID: String, CaseIterable, Identifiable, Sendable {
    case chatGPT = "openai-codex"
    case openAI = "openai"
    case grok = "xai"
    case openRouter = "openrouter"
    case openCodeGo = "opencode-go"
    case exa
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT subscription"
        case .openAI: "OpenAI API key"
        case .grok: "Grok subscription"
        case .openRouter: "OpenRouter"
        case .openCodeGo: "OpenCode Go"
        case .exa: "Exa search"
        }
    }
    public var isSubscription: Bool { self == .chatGPT || self == .grok }
}

extension DefaultAgentCredential {
    /// Claims are display hints only. Provider authorization and billing remain
    /// server decisions; never use this label as proof of entitlement.
    public var accountLabel: String? {
        if let displayName { return displayName }
        guard type == "oauth", let access else { return nil }
        let parts = access.split(separator: ".")
        guard parts.count == 3 else { return accountId }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return accountId }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return (claims["email"] as? String) ?? (profile?["email"] as? String)
            ?? (claims["name"] as? String) ?? accountId ?? (claims["sub"] as? String)
    }
}

extension ProviderAccountCoordinator {
    /// App-wide consumers always resolve global connections, independently of
    /// Default Agent model enablement or a remote workspace's overrides.
    public func appCredentials() async throws -> [String: DefaultAgentCredential] {
        try await prepare("global").credentials
    }

    public func grokDictationCredential() async throws -> DefaultAgentCredential {
        guard let credential = try await appCredentials()[ProviderConnectionID.grok.rawValue],
            credential.type == "oauth", let token = credential.access, !token.isEmpty,
            (credential.expires ?? 0) > Date().timeIntervalSince1970 * 1000
        else {
            throw GrokSpeechError.signInRequired
        }
        return credential
    }
}
