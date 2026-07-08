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

/// A throwable input-validation failure. `OperationError` is a UI banner model
/// (not an `Error`), so throwing paths — the model methods shared with the MCP
/// layer — use this instead. Its `errorDescription` is what an RPC client sees.
struct InputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A registry/pull error re-mapped to a clearer message. `errorDescription` is
/// what an MCP client sees — the generic dispatch catch forwards
/// `error.localizedDescription`, which for a `LocalizedError` is its
/// `errorDescription` — and what the UI banner shows via `OperationError.from`'s
/// fallback. Produced by `Error.translatedPullError` at the pull boundary.
struct PullError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Error {
    /// Translate a recognized image-pull error into a clearer `PullError`, or
    /// return `self` unchanged so unrecognized errors keep their original
    /// `localizedDescription`. Applied at the pull boundary (`MirrorPull`) so
    /// every path — `image_pull`, `compose_up`, and the UI — sees the same
    /// message without each call site re-translating.
    func translatedPullError(arch: String = Arch.hostArchitecture().rawValue) -> Error {
        let msg = localizedDescription.lowercased()
        // Architecture / platform mismatch.
        if msg.contains("unsupported platform") || msg.contains("no matching manifest")
            || msg.contains("manifest not found")
        {
            return PullError(
                "This image doesn't support \(arch) (Apple Silicon). "
                + "It may only be available for amd64/x86_64. "
                + "Try an image with linux/\(arch) support.")
        }
        // Mirror can't serve the image: a 401/403 with a missing Bearer challenge
        // or "no credentials" means the mirror doesn't proxy this repository.
        if (msg.contains("403") || msg.contains("401"))
            && (msg.contains("bearer") || msg.contains("no credentials"))
        {
            let host = Self.registryHost(in: localizedDescription) ?? "the configured registry mirror"
            return PullError(
                "Image could not be fetched from \(host) — the mirror may not proxy this image. "
                + "Check the image name and tag, or configure a mirror that hosts it.")
        }
        // 404 manifest: image or tag genuinely not found at the registry.
        if msg.contains("404") {
            let host = Self.registryHost(in: localizedDescription) ?? "the registry"
            return PullError("Image not found at \(host). Check the image name and tag.")
        }
        return self
    }

    /// Pull the registry host out of a daemon error message, which embeds the
    /// registry URL (e.g. "https://docker.m.daocloud.io/v2/…/manifests/6.2").
    private static func registryHost(in message: String) -> String? {
        guard let r = message.range(of: "https://") else { return nil }
        let rest = message[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == " " || $0 == "\"" || $0 == ")" })
            ?? rest.endIndex
        let host = String(rest[..<end])
        return host.isEmpty ? nil : host
    }
}
