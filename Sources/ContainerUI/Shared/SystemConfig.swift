import ContainerPersistence

/// Loads the container system configuration the same way the CLI does, using the
/// default app-root / install-root TOML layers. Needed by image pull, which must
/// normalize references against the configured registry/DNS settings.
enum SystemConfig {
    static func load() async throws -> ContainerSystemConfig {
        try await ConfigurationLoader.load()
    }
}
