import SwiftUI

/// Shared proxy configuration UI: an enable toggle with address/port fields.
/// Used in two places:
/// - `SystemUnavailableOverlay` (first-run / not-running screen), `centered: true`
///   so the block sits centered under the Start button; no restart prompt (Start
///   applies the proxy).
/// - `SystemView` (settings), leading-aligned, `onRestart` non-nil so that when
///   the *running* system's proxy differs from the edited config, a restart
///   prompt (⚠︎ + Restart link) appears - and only then.
///
/// The address/port fields are always visible (disabled + dimmed when the proxy
/// is off) so toggling doesn't change the section's size - otherwise the switch
/// drifts as the fields appear/disappear. Fields hold real default values
/// (127.0.0.1:7890), not gray placeholders. Edits persist via `ProxyConfig.save`.
struct ProxyConfigSection: View {
    @Binding var config: ProxyConfig
    /// Center the contents (start screen) vs leading-align (settings rows).
    var centered: Bool = false
    /// When non-nil, the system is running - a restart prompt is shown *only* if
    /// the current config diverges from what the system started with. Nil on the
    /// start screen.
    var onRestart: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Toggle(isOn: $config.enabled) {
                Text("Proxy")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 8) {
                Text("Address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("127.0.0.1", text: $config.address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("7890", text: $config.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: config.port) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(5))
                        if digits != new { config.port = digits }
                    }
                if !centered { Spacer(minLength: 0) }
            }
            .disabled(!config.enabled)
            .opacity(config.enabled ? 1 : 0.5)

            // Restart prompt: only when a running system's proxy differs from the
            // edited config (i.e. a restart would change something). Nothing shows
            // otherwise - no hint, no button.
            if let onRestart, config.needsRestartToApply {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Restart the system to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Restart", action: onRestart)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                }
            }
        }
        .onChange(of: config) { _, new in
            ProxyConfig.save(new)
        }
    }
}
