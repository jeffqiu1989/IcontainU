import Foundation
import Observation

@Observable
@MainActor
final class MCPRequestLog {
    private(set) var entries: [Entry] = []
    private let maxEntries = 200

    struct Entry: Identifiable, Codable, Sendable {
        let id: UUID
        let toolName: String
        let timestamp: Date
        let duration: TimeInterval
        let success: Bool
        let errorMessage: String?
        /// Which API key drove this request (nil = unauthenticated/unknown).
        let keyName: String?
        /// The tool call arguments, as a compact JSON string for the detail view.
        let params: String?

        init(
            id: UUID = UUID(),
            toolName: String,
            timestamp: Date = Date(),
            duration: TimeInterval,
            success: Bool,
            errorMessage: String? = nil,
            keyName: String? = nil,
            params: String? = nil
        ) {
            self.id = id
            self.toolName = toolName
            self.timestamp = timestamp
            self.duration = duration
            self.success = success
            self.errorMessage = errorMessage
            self.keyName = keyName
            self.params = params
        }
    }

    func record(
        tool: String,
        duration: TimeInterval,
        success: Bool,
        error: String? = nil,
        keyName: String? = nil,
        params: String? = nil
    ) {
        let entry = Entry(
            toolName: tool,
            duration: duration,
            success: success,
            errorMessage: error,
            keyName: keyName,
            params: params
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }
}
