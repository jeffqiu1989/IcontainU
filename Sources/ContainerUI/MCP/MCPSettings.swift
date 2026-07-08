import Foundation
import Observation

@Observable
@MainActor
final class MCPSettings {
    var isEnabled: Bool = false
    var port: Int = MCPConstants.defaultPort
    var bindAddress: String = MCPConstants.defaultBindAddress
    private(set) var apiKeys: [APIKey] = []

    struct APIKey: Identifiable, Codable, Sendable {
        let id: UUID
        var name: String
        let key: String
        let createdAt: Date

        init(id: UUID = UUID(), name: String, key: String, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.key = key
            self.createdAt = createdAt
        }
    }

    /// On-disk shape. Defined once and used by both save() and load() so the
    /// two can never drift.
    private struct Persist: Codable {
        var isEnabled: Bool
        var port: Int
        var bindAddress: String
        var apiKeys: [APIKey]
    }

    init() {
        load()
    }

    @discardableResult
    func generateKey(name: String) -> APIKey {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let apiKey = APIKey(name: name, key: key)
        apiKeys.append(apiKey)
        save()
        return apiKey
    }

    func deleteKey(id: UUID) {
        apiKeys.removeAll { $0.id == id }
        save()
    }

    func validateKey(_ token: String) -> Bool {
        // Reject empty/blank tokens outright (a stored empty key must never auth).
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        // Constant-time membership: check every key without early-return so the
        // reply timing doesn't leak how many bytes of a key matched. `matched`
        // is OR-accumulated across all keys instead of short-circuiting.
        let candidateBytes = Array(candidate.utf8)
        var matched = false
        for apiKey in apiKeys {
            matched = Self.constantTimeEqual(candidateBytes, Array(apiKey.key.utf8)) || matched
        }
        return matched
    }

    /// Length-independent constant-time byte compare. A length mismatch always
    /// returns false, but only after touching the shorter buffer fully.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let n = min(a.count, b.count)
        for i in 0..<n {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    func save() {
        let persist = Persist(
            isEnabled: isEnabled,
            port: port,
            bindAddress: bindAddress,
            apiKeys: apiKeys
        )
        guard let data = try? JSONEncoder().encode(persist) else { return }
        UserDefaults.standard.set(data, forKey: MCPConstants.settingsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: MCPConstants.settingsKey),
              let persist = try? JSONDecoder().decode(Persist.self, from: data)
        else { return }
        isEnabled = persist.isEnabled
        port = persist.port
        bindAddress = persist.bindAddress
        apiKeys = persist.apiKeys
    }
}
