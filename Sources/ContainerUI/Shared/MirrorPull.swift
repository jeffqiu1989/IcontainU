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
                do {
                    _ = try await existing.config(for: platform)
                } catch {
                    log.debug(
                        "image present but platform config missing, will re-pull",
                        metadata: ["reference": "\(canonical)", "platform": "\(platform)", "error": "\(error)"])
                    throw error
                }
            }
            log.debug("image present locally, skipping pull", metadata: ["reference": "\(canonical)"])
            return existing
        } catch let error as ContainerizationError where error.code == .notFound {
            log.info(
                "image not local or platform missing, pulling",
                metadata: ["reference": "\(canonical)", "original": "\(originalReference)", "error": "\(error)"])
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
    /// After a successful pull, validates that the requested platform actually
    /// exists in the image. The daemon's `ImageStore.pull` creates the tag and
    /// stores the index *before* checking platform availability — a platform
    /// mismatch is only discovered later during `config(for:)`. If the platform
    /// is missing, the freshly-created tag is deleted immediately so no 0 KB
    /// orphan lingers in the image list.
    @MainActor
    static func pull(
        originalReference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        let mirrorReference = RegistryMirrorStore.shared.rewrite(originalReference)

        // No mirror in effect — pull as-is.
        guard mirrorReference != originalReference else {
            return try await pullAndValidate(
                reference: originalReference, platform: platform, config: config,
                progressUpdate: progressUpdate)
        }

        // Pull via the mirror for acceleration.
        let pulled = try await pullAndValidate(
            reference: mirrorReference, platform: platform, config: config,
            progressUpdate: progressUpdate)

        // Retag to the canonical original reference.
        let cleanReference = try ClientImage.normalizeReference(originalReference, containerSystemConfig: config)
        let retagged = try await pulled.tag(new: cleanReference)

        // Drop the mirror-named tag so it does not linger as a duplicate.
        do {
            try await ClientImage.delete(reference: pulled.reference, garbageCollect: false)
        } catch {
            log.warning(
                "failed to remove mirror tag; it may appear as a duplicate image",
                metadata: ["reference": "\(pulled.reference)", "error": "\(error)"])
        }

        return retagged
    }

    /// Pull the reference, then validate that the requested platform is present
    /// in the resulting image. If not, delete the local tag and throw so no
    /// 0 KB orphan remains.
    private static func pullAndValidate(
        reference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        let img = try await ClientImage.pull(
            reference: reference,
            platform: platform,
            containerSystemConfig: config,
            progressUpdate: progressUpdate)

        // Verify the platform exists — ImageStore.pull stores the tag and index
        // even when no manifest matches the requested platform.
        if let platform {
            do {
                _ = try await img.config(for: platform)
            } catch {
                log.debug(
                    "pulled image missing requested platform, removing local tag",
                    metadata: ["reference": "\(img.reference)", "platform": "\(platform)"])
                try? await ClientImage.delete(reference: img.reference, garbageCollect: false)
                throw error
            }
        }

        return img
    }
}
