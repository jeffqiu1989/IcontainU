import ContainerAPIClient
import Foundation

/// A user-facing failure from an explicit action (start/stop/delete/create/pull).
///
/// Distinct from a transient polling error: an `OperationError` is set only by a
/// deliberate operation and is **never** cleared by background refresh — it stays
/// until the user dismisses it or starts another operation of the same kind. This
/// is what lets a failure stay on screen long enough to read and copy, instead of
/// being wiped by the next poll a second or two later.
struct OperationError: Identifiable, Equatable {
    let id = UUID()
    /// Short headline, e.g. "Failed to start container" / "Failed to pull image".
    let title: String
    /// Full `error.localizedDescription`, shown untruncated and copyable.
    let detail: String

    /// The text placed on the pasteboard by the banner's copy button.
    var copyText: String { detail.isEmpty ? title : "\(title)\n\(detail)" }

    static func == (lhs: OperationError, rhs: OperationError) -> Bool {
        lhs.id == rhs.id
    }

    /// Wraps an error for user display. When the error indicates the requested
    /// platform is not available — e.g. pulling an amd64-only image on Apple
    /// Silicon — the detail explains the architecture mismatch instead of
    /// dumping the raw daemon message.
    static func from(_ title: String, error: Error, arch: String = Arch.hostArchitecture().rawValue) -> OperationError {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("unsupported platform") || msg.contains("no matching manifest")
            || msg.contains("manifest not found")
        {
            return OperationError(
                title: title,
                detail: "This image doesn't support \(arch) (Apple Silicon). "
                    + "It may only be available for amd64/x86_64. "
                    + "Try an image with linux/\(arch) support.")
        }
        return OperationError(title: title, detail: error.localizedDescription)
    }
}
