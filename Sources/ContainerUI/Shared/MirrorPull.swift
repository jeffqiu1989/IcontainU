import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

/// Pulls an image honoring the user's registry mirror mappings, then retags it
/// back to the original (canonical) reference so the local image keeps its true
/// identity — the mirror is only a download accelerator and should leave no trace.
///
/// Shared by image pull and machine creation so both behave identically.
enum MirrorPull {
    private static let log = Logger(label: "icontainu.mirror")

    /// Local-first variant of `pull`: return the already-present image when the
    /// canonical reference (with the requested platform) is in the local store,
    /// otherwise fall back to a mirror-aware `pull`.
    ///
    /// This is the right behavior for container creation, which follows Docker
    /// `run` semantics — use the local image when it exists, fetch only when it is
    /// missing. It avoids a redundant registry round-trip on every create and, just
    /// as importantly, avoids re-running the retag/cleanup dance that can otherwise
    /// leave a stray mirror-named tag behind each time.
    @MainActor
    static func fetch(
        originalReference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        let canonical = try ClientImage.normalizeReference(originalReference, containerSystemConfig: config)
        do {
            let existing = try await ClientImage.get(reference: canonical, containerSystemConfig: config)
            // The image exists, but the requested platform may not be pulled — a
            // missing platform throws `.notFound` and routes us to the pull below.
            if let platform {
                _ = try await existing.config(for: platform)
            }
            log.debug("image present locally, skipping pull", metadata: ["reference": "\(canonical)"])
            return existing
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("image not local, pulling", metadata: ["reference": "\(canonical)"])
        }
        return try await pull(
            originalReference: originalReference,
            platform: platform,
            config: config,
            progressUpdate: progressUpdate)
    }

    /// Fetch a reference, routing through a mirror when one is configured, and
    /// return the resulting image under its canonical (mirror-free) reference.
    ///
    /// - When no mirror matches, pulls the reference directly.
    /// - When a mirror matches, pulls via the mirror, retags to the normalized
    ///   original reference, and removes the mirror-named tag (blobs are kept,
    ///   since the canonical tag still references them).
    ///
    /// When the daemon rejects the pull because the image has no matching
    /// manifest for the requested platform (e.g. amd64-only image on Apple
    /// Silicon), it may have already stored the image index locally — leaving a
    /// 0 KB orphan. We clean that up before re-throwing.
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
            return try await pullAndCleanupOrphan(
                reference: originalReference, platform: platform, config: config,
                progressUpdate: progressUpdate)
        }

        // Pull via the mirror for acceleration. Mirror references are always
        // transient — an orphan here can be cleaned up unconditionally.
        let pulled: ClientImage
        do {
            pulled = try await ClientImage.pull(
                reference: mirrorReference,
                platform: platform,
                containerSystemConfig: config,
                progressUpdate: progressUpdate)
        } catch {
            // Stray mirror-named tag created by a failed pull → best-effort delete.
            guard isPlatformMismatch(error) else { throw error }
            try? await ClientImage.delete(reference: mirrorReference, garbageCollect: false)
            throw error
        }

        // Retag to the canonical original reference (correct for any source: a
        // bare name resolves under docker.io, a domained name keeps its domain).
        let cleanReference = try ClientImage.normalizeReference(originalReference, containerSystemConfig: config)
        let retagged = try await pulled.tag(new: cleanReference)

        // Drop the mirror-named tag so it does not linger as a duplicate entry in
        // the image list (the canonical tag already references the same blobs).
        // Best-effort: if it fails the canonical tag is still usable, but log it —
        // a silently-failed cleanup is exactly what produces a stray second tag.
        do {
            try await ClientImage.delete(reference: pulled.reference, garbageCollect: false)
        } catch {
            log.warning(
                "failed to remove mirror tag; it may appear as a duplicate image",
                metadata: ["reference": "\(pulled.reference)", "error": "\(error)"])
        }

        return retagged
    }

    /// Pull directly (no mirror) and clean up a potential orphan when the daemon
    /// writes the image index before rejecting the platform — safe because we
    /// only delete when the image did not exist locally before this pull.
    private static func pullAndCleanupOrphan(
        reference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        // Remember whether this image already had a local entry so we can decide
        // whether a failed pull left a new orphan.
        let existedBefore = (try? await ClientImage.get(
            reference: reference, containerSystemConfig: config)) != nil

        do {
            return try await ClientImage.pull(
                reference: reference,
                platform: platform,
                containerSystemConfig: config,
                progressUpdate: progressUpdate)
        } catch {
            // The daemon may have stored the index before rejecting the platform.
            // Only clean up images that were NOT present before this pull attempt;
            // a previously-existing image (e.g. pulled with a different platform)
            // must not be removed.
            if !existedBefore, isPlatformMismatch(error) {
                log.debug(
                    "removing orphan image from failed platform-mismatch pull",
                    metadata: ["reference": "\(reference)"])
                try? await ClientImage.delete(reference: reference, garbageCollect: false)
            }
            throw error
        }
    }

    private static func isPlatformMismatch(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("unsupported platform")
            || msg.contains("no matching manifest")
            || msg.contains("manifest not found")
    }
}
