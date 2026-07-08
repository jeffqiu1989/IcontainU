import Foundation

enum MCPConstants {
    static let defaultPort: Int = 3000
    static let defaultBindAddress = "127.0.0.1"
    static let settingsKey = "mcpSettings"
    static let sessionTimeout: TimeInterval = 3600
    static let maxRequestBodyBytes = 1 << 20  // 1 MB
    static let endpoint = "/mcp"
}
