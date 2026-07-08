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

        init(
            id: UUID = UUID(),
            toolName: String,
            timestamp: Date = Date(),
            duration: TimeInterval,
            success: Bool,
            errorMessage: String? = nil
        ) {
            self.id = id
            self.toolName = toolName
            self.timestamp = timestamp
            self.duration = duration
            self.success = success
            self.errorMessage = errorMessage
        }
    }

    func record(tool: String, duration: TimeInterval, success: Bool, error: String? = nil) {
        let entry = Entry(
            toolName: tool,
            duration: duration,
            success: success,
            errorMessage: error
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }
}
