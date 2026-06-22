import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import TerminalProgress

/// Pulls an image honoring the user's registry mirror mappings, then retags it
/// back to the original (canonical) reference so the local image keeps its true
/// identity — the mirror is only a download accelerator and should leave no trace.
///
/// Shared by image pull and machine creation so both behave identically.
enum MirrorPull {
    /// Fetch a reference, routing through a mirror when one is configured, and
    /// return the resulting image under its canonical (mirror-free) reference.
    ///
    /// - When no mirror matches, pulls the reference directly.
    /// - When a mirror matches, pulls via the mirror, retags to the normalized
    ///   original reference, and removes the mirror-named tag (blobs are kept,
    ///   since the canonical tag still references them).
    @MainActor
    static func pull(
        originalReference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        let mirrorReference = RegistryMirrorStore.shared.rewrite(originalReference)

        // No mirror in effect — pull as-is; pull normalizes internally.
        guard mirrorReference != originalReference else {
            return try await ClientImage.pull(
                reference: originalReference,
                platform: platform,
                containerSystemConfig: config,
                progressUpdate: progressUpdate)
        }

        // Pull via the mirror for acceleration.
        let pulled = try await ClientImage.pull(
            reference: mirrorReference,
            platform: platform,
            containerSystemConfig: config,
            progressUpdate: progressUpdate)

        // Retag to the canonical original reference (correct for any source: a
        // bare name resolves under docker.io, a domained name keeps its domain).
        let cleanReference = try ClientImage.normalizeReference(originalReference, containerSystemConfig: config)
        let retagged = try await pulled.tag(new: cleanReference)

        // Drop the mirror-named tag using the exact stored reference. Best-effort:
        // if it fails, the canonical tag is already in place and usable.
        try? await ClientImage.delete(reference: pulled.reference, garbageCollect: false)

        return retagged
    }
}
