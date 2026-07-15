import Foundation

/// User-configured HTTP proxy for the container system.
///
/// When active, the address:port is passed to `container system start` as
/// `http_proxy`/`https_proxy`/`no_proxy` env vars (see `TerminalLauncher`),
/// so the apiserver routes kernel downloads and image pulls through it. The
/// apiserver reads these via `ProxyUtils.proxyFromEnvironment` (it does NOT
/// use the macOS system proxy), so the env var is the only way to make a
/// local proxy take effect. Verified: a bogus proxy here makes pulls fail with
/// "Connection refused"; the real proxy makes them succeed even when the
/// registry is blocked direct.
///
/// Stored in UserDefaults so `TerminalLauncher.startSystem` (env injection)
/// and the UI read the same value.
struct ProxyConfig: Equatable {
    var enabled: Bool
    var address: String
    var port: String

    static var current: ProxyConfig {
        let d = UserDefaults.standard
        // Default to 127.0.0.1:7890 (the common local proxy port, e.g. Clash) so
        // the fields hold a real editable value, not a gray placeholder. Empty
        // stored strings (from an earlier build) also fall back to the default.
        let addr = d.string(forKey: addressKey)
        let port = d.string(forKey: portKey)
        return ProxyConfig(
            enabled: d.bool(forKey: enabledKey),
            address: (addr?.isEmpty == false) ? addr! : "127.0.0.1",
            port: (port?.isEmpty == false) ? port! : "7890")
    }

    static func save(_ config: ProxyConfig) {
        let d = UserDefaults.standard
        d.set(config.enabled, forKey: enabledKey)
        d.set(config.address, forKey: addressKey)
        d.set(config.port, forKey: portKey)
    }

    /// The proxy env value that was in effect at the last `container system start`,
    /// so the UI can tell whether the current config differs and a restart is
    /// needed. Stored as the `http://...` string, or "" for "no proxy". Written by
    /// `TerminalLauncher.startSystem`.
    static var appliedURLString: String {
        get { UserDefaults.standard.string(forKey: appliedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: appliedKey) }
    }

    /// True when the current config differs from what the running system started
    /// with - i.e. a restart is required for it to take effect.
    var needsRestartToApply: Bool {
        (httpURLString ?? "") != ProxyConfig.appliedURLString
    }

    /// Whether the proxy is usable: enabled, non-empty address, port in 1-65535.
    /// `TerminalLauncher` only injects env when this is true, so a half-entered
    /// config is ignored rather than breaking all downloads.
    var isActive: Bool {
        guard enabled else { return false }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let p = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
        return (1...65535).contains(p)
    }

    /// `http://<address>:<port>` for the env var, or nil when inactive.
    var httpURLString: String? {
        guard isActive else { return nil }
        return "http://\(address.trimmingCharacters(in: .whitespaces)):\(port.trimmingCharacters(in: .whitespaces))"
    }

    private static let enabledKey = "proxyEnabled"
    private static let addressKey = "proxyAddress"
    private static let portKey = "proxyPort"
    private static let appliedKey = "proxyApplied"
}
