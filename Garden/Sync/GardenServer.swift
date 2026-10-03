import Foundation

/// Client for the user's own Garden Worker (worker/src/index.ts). The base URL lives in UserDefaults;
/// the device token in iCloud Keychain.
struct GardenServer: Sendable {
    let baseURL: URL
    let token: String

    static let urlKey = "serverURL"

    /// The paired server, if any.
    static var current: GardenServer? {
        guard let raw = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: raw),
              let token = Keychain.string(for: "serverToken")
        else { return nil }
        return GardenServer(baseURL: url, token: token)
    }

    // MARK: Pairing

    /// Swaps a pairing code (from `npm run pair`) for a device token and remembers the server.
    static func pair(url raw: String, code: String, deviceName: String) async throws -> GardenServer {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), url.host != nil else {
            throw ServerError.invalidURL
        }
        struct Body: Encodable { let code: String; let deviceName: String }
        struct Reply: Decodable { let token: String }
        let reply: Reply = try await send(url: url.appending(path: "v1/pair"), method: "POST", token: nil,
                                          body: Body(code: code.trimmingCharacters(in: .whitespaces), deviceName: deviceName))
        UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
        Keychain.set(reply.token, for: "serverToken")
        return GardenServer(baseURL: url, token: reply.token)
    }

    func unpair() async {
        _ = try? await GardenServer.sendRaw(url: baseURL.appending(path: "v1/devices/self"), method: "DELETE", token: token, body: Optional<Int>.none)
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        Keychain.set(nil, for: "serverToken")
    }

    // MARK: Endpoints

    struct ItemStatus: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let institution: String?
        let status: String
        let executionStatus: String
        let lastUpdatedAt: Date?
        let consentExpiresAt: Date?
        let error: String?
    }

    func items() async throws -> [ItemStatus] {
        struct Reply: Decodable { let items: [ItemStatus] }
        let reply: Reply = try await Self.send(url: baseURL.appending(path: "v1/items"), method: "GET", token: token, body: Optional<Int>.none)
        return reply.items
    }

    func setItems(_ itemIds: [String]) async throws -> [ItemStatus] {
        struct Body: Encodable { let itemIds: [String] }
        struct Reply: Decodable { let items: [ItemStatus] }
        let reply: Reply = try await Self.send(url: baseURL.appending(path: "v1/items"), method: "PUT", token: token, body: Body(itemIds: itemIds))
        return reply.items
    }

    func snapshot(itemId: String, from: Date?) async throws -> PluggySnapshot {
        var url = baseURL.appending(path: "v1/items/\(itemId)/snapshot")
        if let from {
            url.append(queryItems: [URLQueryItem(name: "from", value: from.formatted(.iso8601.year().month().day()))])
        }
        return try await Self.send(url: url, method: "GET", token: token, body: Optional<Int>.none, timeout: 120)
    }

    /// True when this device holds the single-writer ingestion lease.
    func acquireLease() async throws -> Bool {
        do {
            let data = try await Self.sendRaw(url: baseURL.appending(path: "v1/lease"), method: "POST", token: token, body: Optional<Int>.none)
            return !data.isEmpty
        } catch ServerError.http(409, _) {
            return false
        }
    }

    // MARK: Transport

    enum ServerError: LocalizedError {
        case invalidURL
        case http(Int, String)
        case unreachable
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: String(localized: "Endereço do servidor inválido.")
            case .unreachable: String(localized: "Não foi possível falar com o servidor.")
            case .unreadable(let detail): String(localized: "Resposta do Pluggy em formato inesperado: \(detail)")
            case .http(401, "invalid_code"): String(localized: "Código inválido ou expirado. Gere outro com npm run pair.")
            case .http(401, _): String(localized: "Este aparelho não está mais conectado ao servidor.")
            case .http(429, _): String(localized: "Muitas tentativas. Tente de novo em uma hora.")
            case .http(503, _): String(localized: "O Pluggy pediu uma pausa. Tentaremos de novo em breve.")
            case .http(422, let message): String(localized: "Item não encontrado no Pluggy (\(message)).")
            case .http(let status, let message): String(localized: "Erro do servidor (\(status)): \(message)")
            }
        }
    }

    private static func send<Body: Encodable, Reply: Decodable>(url: URL, method: String, token: String?, body: Body?,
                                                                timeout: TimeInterval = 30) async throws -> Reply {
        let data = try await sendRaw(url: url, method: method, token: token, body: body, timeout: timeout)
        do {
            return try decoder.decode(Reply.self, from: data)
        } catch let error as DecodingError {
            throw ServerError.unreadable(Self.describe(error))
        }
    }

    private static func sendRaw<Body: Encodable>(url: URL, method: String, token: String?, body: Body?,
                                                 timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServerError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(FailureBody.self, from: data))?.error ?? ""
            throw ServerError.http(status, message)
        }
        return data
    }

    private struct FailureBody: Decodable { let error: String }

    /// "transactions › acc-1 › 3 › date: Unparseable date …" — enough to fix the decoder.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: " › ")
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context.codingPath + [key])) ausente"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = PluggyDate.parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)"))
        }
        return decoder
    }()
}

enum PluggyDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
            ?? (try? Date(text + "T12:00:00Z", strategy: .iso8601))  // date-only fields
    }
}
