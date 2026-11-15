import Foundation

/// How a gateway expects the API key: `Authorization: Bearer <key>` or an `x-api-key: <key>` header.
public enum AuthScheme: String, Codable, Sendable, CaseIterable {
    case bearer
    case xAPIKey = "x-api-key"

    public var title: String {
        switch self {
        case .bearer: return "Bearer"
        case .xAPIKey: return "x-api-key"
        }
    }
}

/// The wire protocol a gateway speaks.
public enum APIFormat: String, Codable, Sendable, CaseIterable {
    /// OpenAI-compatible `/chat/completions`: OpenAI, OpenRouter, LiteLLM, Ollama, vLLM and most proxies.
    case openAI = "openai"
    /// Anthropic's `/messages`.
    case anthropic

    public var title: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic Messages"
        }
    }
}

/// A thinking block from an Anthropic model, kept so it can go back to the API during a tool-use loop.
public struct ReasoningBlock: Codable, Equatable, Sendable {
    public var text: String
    public var signature: String?
    /// Set for redacted thinking, whose content arrives encrypted.
    public var redactedData: String?

    public init(text: String, signature: String? = nil, redactedData: String? = nil) {
        self.text = text
        self.signature = signature
        self.redactedData = redactedData
    }
}

/// An extra header sent with every request to a gateway, e.g. for routing or a tenant.
public struct HTTPHeader: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// How hard a reasoning model thinks, sent as `reasoning_effort`. No effort means the provider decides.
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra"
        case .max: return "Max"
        }
    }
}

/// A gateway: an OpenAI-compatible base URL plus how to talk to it and which models it has.
/// The API key lives in the secret store.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    /// The model list set by hand. While it is empty the picker shows `discoveredModels`.
    public var models: [String]
    public var defaultModel: String?
    /// Context size of the models on this endpoint, in tokens; nil means `defaultContextWindow`.
    public var contextWindow: Int?
    /// nil means bearer.
    public var authScheme: AuthScheme?
    public var headers: [HTTPHeader]?
    /// Seconds to wait for the next bytes of a streamed answer; nil means `defaultIdleTimeout`.
    public var idleTimeout: Double?
    /// Fill the model picker from `/models`; nil means on.
    public var discoverModels: Bool?
    /// What `/models` returned last time.
    public var discoveredModels: [String]?
    /// Effort a session starts at on this gateway; nil leaves it to the provider.
    public var defaultEffort: Effort?
    /// nil means OpenAI-compatible, or Anthropic for api.anthropic.com.
    public var apiFormat: APIFormat?
    /// Anthropic format only: the answer's token limit; nil means `defaultMaxTokens`.
    public var maxTokens: Int?

    public init(id: UUID = UUID(), name: String, baseURL: String, models: [String] = [], defaultModel: String? = nil,
                contextWindow: Int? = nil, authScheme: AuthScheme? = nil, headers: [HTTPHeader]? = nil,
                idleTimeout: Double? = nil, discoverModels: Bool? = nil, discoveredModels: [String]? = nil,
                defaultEffort: Effort? = nil, apiFormat: APIFormat? = nil, maxTokens: Int? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.contextWindow = contextWindow
        self.authScheme = authScheme
        self.headers = headers
        self.idleTimeout = idleTimeout
        self.discoverModels = discoverModels
        self.discoveredModels = discoveredModels
        self.defaultEffort = defaultEffort
        self.apiFormat = apiFormat
        self.maxTokens = maxTokens
    }

    public static let defaultContextWindow = 128_000
    public static let defaultIdleTimeout: Double = 300
    public static let defaultMaxTokens = 32_000

    public var secretKey: String { "profile.\(id.uuidString).apikey" }
    /// What the model picker offers: the hand-made list, or else what discovery found.
    public var pickerModels: [String] { models.isEmpty ? (discoveredModels ?? []) : models }
    public var preferredModel: String? { defaultModel ?? pickerModels.first }
    public var contextLimit: Int { contextWindow.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultContextWindow }
    public var format: APIFormat { apiFormat ?? Self.guessFormat(baseURL) }
    /// Anthropic's own API takes the key as x-api-key; everything else defaults to a bearer token.
    public var auth: AuthScheme { authScheme ?? (format == .anthropic ? .xAPIKey : .bearer) }
    public var outputLimit: Int { maxTokens.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultMaxTokens }
    public var extraHeaders: [HTTPHeader] { headers ?? [] }
    public var streamTimeout: Double { idleTimeout.flatMap { $0 >= 5 ? $0 : nil } ?? Self.defaultIdleTimeout }
    public var discovers: Bool { discoverModels ?? true }

    /// A request to this gateway with its format, auth scheme, headers and timeout.
    public func chatRequest(apiKey: String, model: String, messages: [ChatMessage], effort: Effort? = nil) -> ChatRequest {
        ChatRequest(baseURL: baseURL, apiKey: apiKey, model: model, messages: messages,
                    authScheme: auth, headers: extraHeaders, effort: effort, idleTimeout: streamTimeout,
                    format: format, maxTokens: outputLimit)
    }

    /// api.anthropic.com speaks the Anthropic format; any other host is taken as OpenAI-compatible.
    public static func guessFormat(_ baseURL: String) -> APIFormat {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host == "api.anthropic.com" ? .anthropic : .openAI
    }

    /// Reads "200k", "1m", "131,072" and the like; nil for anything else or under 1k.
    public static func parseContextWindow(_ text: String) -> Int? {
        var value = text.lowercased().filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
        var scale = 1.0
        if value.hasSuffix("k") {
            scale = 1_000
            value.removeLast()
        } else if value.hasSuffix("m") {
            scale = 1_000_000
            value.removeLast()
        }
        guard let number = Double(value), number.isFinite else { return nil }
        let tokens = number * scale
        guard tokens >= 1_000, tokens <= 100_000_000 else { return nil }
        return Int(tokens)
    }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// OpenSSH-format host key recorded on first connect; later connects must match it.
    public var trustedHostKey: String?
    /// Project folder on the host. When set, the file tools work there and commands start there.
    public var workingDirectory: String?
    /// Project folders used lately, newest first.
    public var recentDirectories: [String]?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, trustedHostKey: String? = nil, workingDirectory: String? = nil,
                recentDirectories: [String]? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.trustedHostKey = trustedHostKey
        self.workingDirectory = workingDirectory
        self.recentDirectories = recentDirectories
    }

    public mutating func remember(directory: String) {
        var list = (recentDirectories ?? []).filter { $0 != directory }
        list.insert(directory, at: 0)
        recentDirectories = Array(list.prefix(8))
    }

    public var secretKey: String { "host.\(id.uuidString).secret" }
    public var passphraseKey: String { "host.\(id.uuidString).passphrase" }
    public var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON object string as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public func string(_ key: String) -> String? { argumentValues[key] as? String }

    public func number(_ key: String) -> Double? {
        let value = argumentValues[key]
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// A whole number, clamped so a silly value cannot trap.
    public func integer(_ key: String) -> Int? {
        guard let value = number(key), value.isFinite else { return nil }
        return Int(min(max(value, -1_000_000_000), 1_000_000_000))
    }

    public func flag(_ key: String) -> Bool {
        let value = argumentValues[key]
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let number = value as? Int { return number != 0 }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?
    /// Images attached to a user message, as data URLs.
    public var images: [String]?
    /// Thinking blocks of an assistant message, for gateways that need them back (Anthropic).
    public var reasoning: [ReasoningBlock]?

    public init(role: Role, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil,
                images: [String]? = nil, reasoning: [ReasoningBlock]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.images = images
        self.reasoning = reasoning
    }
}

/// One block in the on-screen transcript.
public struct TranscriptItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, info, error
        /// The model's reasoning, shown dimmed and left out of exports.
        case thinking
    }

    public enum Status: String, Codable, Sendable {
        case running, ok, failed, denied
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Tool blocks only: the one-line description, e.g. `ssh web1 $ uptime`.
    public var title: String?
    public var status: Status?

    public init(id: UUID = UUID(), kind: Kind, text: String, title: String? = nil, status: Status? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.status = status
    }
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]

    public init(id: UUID = UUID(), title: String = "new session", createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
    }

    public var isEmpty: Bool { messages.isEmpty }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    /// Ask before anything that changes state or leaves the device.
    case ask
    /// Run every tool call without asking.
    case auto
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var activeModel: String?
    public var activeHostID: UUID?
    public var themeID: String
    public var fontSize: Double
    public var approvalMode: ApprovalMode
    public var systemPrompt: String
    /// Reasoning effort for new requests; nil sends none.
    public var effort: Effort?
    /// New sessions go back to the gateway's default model and effort.
    public var alwaysStartWithDefault: Bool?

    public init(activeProfileID: UUID? = nil, activeModel: String? = nil, activeHostID: UUID? = nil,
                themeID: String = Theme.desktop.id, fontSize: Double = 15,
                approvalMode: ApprovalMode = .ask, systemPrompt: String = "",
                effort: Effort? = nil, alwaysStartWithDefault: Bool? = nil) {
        self.activeProfileID = activeProfileID
        self.activeModel = activeModel
        self.activeHostID = activeHostID
        self.themeID = themeID
        self.fontSize = fontSize
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
        self.effort = effort
        self.alwaysStartWithDefault = alwaysStartWithDefault
    }
}
