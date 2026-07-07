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

    /// Built-in ghcr.io mirrors tried as a last resort for infrastructure images
    /// (e.g. the vminit init image) when the user has no ghcr.io mapping
    /// configured, or the configured one is unreachable. Infrastructure images
    /// are required for the app to function, so they get blessed mirrors
    /// independent of the user's `RegistryMirrorStore` — mirroring how the
    /// kernel download falls back to a fixed set of GitHub proxies. A fresh
    /// install with no registry mirrors must still be able to create a container.
    private static let blessedGHCRMirrors = ["ghcr.m.daocloud.io", "ghcr.1ms.run"]

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

    /// Resolve an infrastructure image (one the app needs to function, e.g. the
    /// vminit init image) local-first, honoring the user's registry mirrors,
    /// then falling back to the built-in ghcr.io mirrors above.
    ///
    /// Unlike `fetch` (used for user images, which respect the user's mirror
    /// config and fail otherwise), infrastructure images must be obtainable on a
    /// fresh install with no mirrors configured. So a failure of the primary
    /// fetch — image not local AND the user's configured mirror (or a direct
    /// pull) unreachable — triggers the blessed mirrors.
    @MainActor
    static func fetchInfraImage(
        originalReference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        // Local-first + the user's configured mirrors. Returns immediately when
        // the image is already cached, so the blessed fallback never runs on the
        // hot path. A throw means the image isn't local and the configured mirror
        // (or a direct pull) couldn't reach it — try the blessed mirrors below.
        var primaryError: Error?
        do {
            return try await fetch(
                originalReference: originalReference,
                platform: platform,
                config: config,
                progressUpdate: progressUpdate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            primaryError = error
            log.info(
                "infra image not reachable via user config, trying blessed ghcr mirrors",
                metadata: ["reference": "\(originalReference)", "error": "\(error)"])
        }

        // Blessed mirrors only apply to ghcr.io sources — rewriting a non-ghcr
        // reference to a ghcr mirror would point at the wrong image. A non-ghcr
        // infra image (unusual) surfaces the primary failure directly.
        var lastError = primaryError
        for mirror in blessedGHCRMirrors {
            guard let mirrorReference = rewriteGHCR(originalReference, to: mirror) else { continue }
            do {
                log.info(
                    "pulling infra image via blessed mirror",
                    metadata: ["reference": "\(originalReference)", "mirror": "\(mirror)"])
                return try await pullViaMirror(
                    originalReference: originalReference,
                    mirrorReference: mirrorReference,
                    platform: platform,
                    config: config,
                    progressUpdate: progressUpdate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.warning(
                    "blessed mirror failed, trying next",
                    metadata: ["mirror": "\(mirror)", "error": "\(error)"])
                lastError = error
            }
        }

        // All mirrors failed (or the reference wasn't ghcr). Surface the last
        // failure so the user sees why rather than a generic error.
        throw lastError ?? ContainerizationError(
            .internalError,
            message: "unable to fetch infra image \(originalReference)")
    }

    /// Rewrite a ghcr.io reference to use `mirror` as its domain, preserving the
    /// path and tag/digest. Returns nil if the reference isn't a ghcr.io source
    /// (blessed mirrors only apply to ghcr.io). Mirrors `RegistryMirrorStore`'s
    /// rewrite but with a fixed mirror instead of a user-configured mapping.
    private static func rewriteGHCR(_ reference: String, to mirror: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard let parsed = try? Reference.parse(trimmed),
            let domain = parsed.domain,
            domain.caseInsensitiveCompare("ghcr.io") == .orderedSame
        else { return nil }
        var result = "\(mirror)/\(parsed.path)"
        if let tag = parsed.tag {
            result += ":\(tag)"
        } else if let digest = parsed.digest {
            result += "@\(digest)"
        }
        return result
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

        // Pull via the mirror for acceleration, then retag to the canonical
        // original reference and drop the mirror-named tag.
        return try await pullViaMirror(
            originalReference: originalReference,
            mirrorReference: mirrorReference,
            platform: platform,
            config: config,
            progressUpdate: progressUpdate)
    }

    /// Pull via a specific mirror reference, then retag the result back to the
    /// canonical (mirror-free) original reference and drop the mirror-named tag
    /// so it does not linger as a duplicate. Shared by `pull` (the user's
    /// configured mirror) and `fetchInfraImage` (the built-in blessed mirrors).
    private static func pullViaMirror(
        originalReference: String,
        mirrorReference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
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
    ///
    /// Transient network failures (connect/read timeouts, connection resets —
    /// the mirror occasionally times out mid-pull) are retried up to 3 times
    /// with a short backoff; a fresh attempt usually succeeds. Non-transient
    /// failures (404, auth/403, arch mismatch) fail fast. On final failure the
    /// error is translated to a clearer `PullError` when recognized, so every
    /// caller — `image_pull`, `compose_up`, and the UI — gets the same message.
    private static func pullAndValidate(
        reference: String,
        platform: Platform?,
        config: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?
    ) async throws -> ClientImage {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if error.isCancellation { throw CancellationError() }
                // Retry only transient errors, and only while attempts remain.
                guard error.isTransientPullError, attempt < maxAttempts else {
                    throw error.translatedPullError()
                }
                log.warning(
                    "transient pull error, retrying",
                    metadata: [
                        "reference": "\(reference)",
                        "attempt": "\(attempt)/\(maxAttempts)",
                        "error": "\(error)",
                    ])
                try await Task.sleep(for: .seconds(2))
            }
        }
        // Unreachable: the loop returns on success or throws on every failure
        // path. This satisfies the compiler's exhaustiveness check.
        throw ContainerizationError(.internalError, message: "pull failed: \(reference)")
    }
}
