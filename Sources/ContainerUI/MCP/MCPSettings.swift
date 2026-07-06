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
        apiKeys.contains { $0.key == token }
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
