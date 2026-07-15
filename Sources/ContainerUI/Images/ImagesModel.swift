import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Observation
import TerminalProgress

@Observable
@MainActor
final class ImagesModel {
    private(set) var images: [ContainerImage] = []
    /// Transient list-fetch failure: managed entirely by `refresh`.
    private(set) var pollError: String?
    /// Failure of an explicit action (pull/delete): never cleared by polling.
    private(set) var lastError: OperationError?
    private(set) var pull: OperationProgress?
    private var pullTask: Task<Void, Never>?
    /// Generation token guarding `pull` against superseded tasks — a cancelled
    /// task's server-side pull can't be aborted, so its `defer` must not nil a
    /// newer task's bar. Mirrors `MachinesModel.createGeneration`; see the plan
    /// at `.claude/plans/pull-machine-wiggly-squirrel.md`.
    private var pullGeneration = 0

    /// Active image export (save to tar). Indeterminate only — `ClientImage.save`
    /// has no progress handler, unlike pull/push/unpack.
    private(set) var export: OperationProgress?
    private var exportTask: Task<Void, Never>?
    private var exportGeneration = 0

    /// Active image import (load from tar). Two phases: "Loading tar archive"
    /// (indeterminate, `load` has no progress handler) then "Unpacking…" (byte
    /// level, via each loaded image's `unpack`).
    private(set) var importProgress: OperationProgress?
    private var importTask: Task<Void, Never>?
    private var importGeneration = 0

    func clearError() { lastError = nil }

    /// Images grouped by repository for the card grid — one card per repository,
    /// each listing its tags. Computed on demand from `images`.
    var repoGroups: [ImageRepoGroup] {
        ImageRepoGroup.group(images)
    }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        do {
            let config = try await SystemConfig.load()
            let raw = try await ClientImage.list().filter { img in
                !Utility.isInfraImage(
                    name: img.reference,
                    builderImage: config.build.image,
                    initImage: config.vminit.image)
            }
            var resources: [ContainerImage] = []
            for image in raw {
                resources.append(try await image.toImageResource(containerSystemConfig: config))
            }
            images = resources.sorted { $0.displayReference < $1.displayReference }
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func delete(_ image: ContainerImage) async {
        lastError = nil
        do {
            try await deleteThrowing(image)
        } catch {
            lastError = OperationError(
                title: "Failed to delete image", detail: error.localizedDescription)
        }
    }

    /// Throwing core shared with the MCP layer.
    func deleteThrowing(_ image: ContainerImage) async throws {
        // Delete by the full reference (e.g. docker.io/library/nginx:latest),
        // not the shortened displayReference — the backend matches the stored
        // canonical reference, so a denormalized name would not be found.
        try await ClientImage.delete(reference: image.name, garbageCollect: true)
        await refresh()
    }

    /// The host's Linux platform (e.g. linux/arm64 on Apple silicon). Pulling and
    /// unpacking only this platform avoids fetching other architectures' variants,
    /// which cannot run on this machine. (container defaults to all platforms.)
    private var currentLinuxPlatform: Platform? {
        try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
    }

    func cancelPull() {
        pullGeneration &+= 1
        pullTask?.cancel()
        pull = nil
    }

    func startPullImage(reference: String) {
        cancelPull()
        let generation = pullGeneration
        pullTask = Task { [weak self] in
            await self?._pullImage(reference: reference, generation: generation)
        }
    }

    /// Pulls a reference and unpacks it (matching the CLI), reporting progress.
    ///
    /// Fetch and unpack are coordinated as two distinct phases: a
    /// `ProgressTaskCoordinator` makes the fetch task non-current the instant
    /// unpack begins, so any late fetch events are dropped instead of bumping
    /// the unpack bar — the same technique the CLI uses to keep progress stable.
    private func _pullImage(reference: String, generation: Int) async {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        lastError = nil
        let platform = currentLinuxPlatform
        let viaMirror = RegistryMirrorStore.shared.rewrite(trimmed) != trimmed
        let viaProxy = !ProxyConfig.appliedURLString.isEmpty

        let progress = OperationProgress()
        progress.beginPhase(
            viaMirror
                ? String(localized: "Pulling \(trimmed) via mirror…")
                : viaProxy ? String(localized: "Pulling \(trimmed) via proxy…")
                : String(localized: "Pulling \(trimmed)…"))
        // Only the current generation owns `pull`: a superseded task (cancelled but
        // still running its server-side pull) must not set or clear it. Mirrors the
        // `creating`/`pulling` guards in the machine/container models.
        guard pullGeneration == generation else { return }
        pull = progress
        defer { if pullGeneration == generation { pull = nil } }

        // Apply events to OUR `progress`, not `self.pull`, so a stale task's late
        // events land on an orphan nobody observes instead of the active bar.
        let progressHandler: ProgressUpdateHandler = { [weak progress] events in
            await progress?.apply(events)
        }

        let coordinator = ProgressTaskCoordinator()
        defer { Task { await coordinator.finish() } }

        do {
            let config = try await SystemConfig.load()
            // Local-first: when the exact reference (with the host platform) is
            // already present, return it without a registry round-trip — a pinned
            // tag like alpine:3.24 never changes, so re-verifying over a slow
            // network is wasted. Only a missing image goes out, through any
            // configured mirror, then retagged to the canonical reference.
            let fetchTask = await coordinator.startTask()
            let image = try await MirrorPull.fetch(
                originalReference: trimmed,
                platform: platform,
                config: config,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressHandler))

            // The pull's XPC `send` does not abort on cancel, so check at the phase
            // boundary before unpacking. See `MachinesModel._create` for rationale.
            try Task.checkCancellation()

            let unpackTask = await coordinator.startTask()
            progress.beginPhase("Unpacking…")
            try await image.unpack(
                platform: platform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressHandler))
            try Task.checkCancellation()
            await refresh()
        } catch is CancellationError {
            // User cancelled — not an error. defer sets pull = nil.
        } catch {
            // A cancellation wrapped into `ContainerizationError(cause:
            // CancellationError)` is also a user abort, not a failure. A superseded
            // task resumed after its XPC call ignored cancellation must not clobber
            // the active task's error — drop it.
            guard pullGeneration == generation else { return }
            guard !error.isCancellation else { return }
            lastError = .from("Failed to pull image", error: error)
        }
    }

    // MARK: - Export (save to tar)

    func cancelExport() {
        exportGeneration &+= 1
        exportTask?.cancel()
        export = nil
    }

    func startExport(reference: String, outputURL: URL) {
        cancelExport()
        let generation = exportGeneration
        exportTask = Task { [weak self] in
            await self?._exportImage(reference: reference, outputURL: outputURL, generation: generation)
        }
    }

    /// Saves a single reference as an OCI tar archive for the host platform only.
    /// `ClientImage.save` reports no progress, so the bar stays indeterminate —
    /// matching the CLI's `ImageSave` command. On failure or cancel the partially
    /// written file is removed so the user isn't left with a truncated archive.
    private func _exportImage(reference: String, outputURL: URL, generation: Int) async {
        lastError = nil
        let platform = currentLinuxPlatform

        let progress = OperationProgress()
        progress.beginPhase(String(localized: "Saving \(reference)…"))
        guard exportGeneration == generation else { return }
        export = progress
        defer { if exportGeneration == generation { export = nil } }

        do {
            let config = try await SystemConfig.load()
            try Task.checkCancellation()
            try await ClientImage.save(
                references: [reference],
                out: outputURL.path,
                platform: platform,
                containerSystemConfig: config)
            try Task.checkCancellation()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard exportGeneration == generation else { return }
            guard !error.isCancellation else { return }
            lastError = .from("Failed to export image", error: error)
        }
    }

    // MARK: - Import (load from tar)

    func cancelImport() {
        importGeneration &+= 1
        importTask?.cancel()
        importProgress = nil
    }

    func startImport(inputURL: URL) {
        cancelImport()
        let generation = importGeneration
        importTask = Task { [weak self] in
            await self?._importImage(inputURL: inputURL, generation: generation)
        }
    }

    /// Loads images from an OCI tar archive, then unpacks each — the same two
    /// phases as the CLI's `ImageLoad`. `load` itself reports no progress
    /// (indeterminate "Loading tar archive"), but the subsequent `unpack` of each
    /// loaded image is byte-level. Unpack uses `platform: nil` (not host-only like
    /// pull) so the framework picks a default platform from the archive, avoiding
    /// a mismatch error when the archive lacks the host architecture.
    private func _importImage(inputURL: URL, generation: Int) async {
        lastError = nil

        let progress = OperationProgress()
        progress.beginPhase("Loading tar archive…")
        guard importGeneration == generation else { return }
        importProgress = progress
        defer { if importGeneration == generation { importProgress = nil } }

        let progressHandler: ProgressUpdateHandler = { [weak progress] events in
            await progress?.apply(events)
        }

        let coordinator = ProgressTaskCoordinator()
        defer { Task { await coordinator.finish() } }

        do {
            let result = try await ClientImage.load(from: inputURL.path, force: false)
            try Task.checkCancellation()

            let unpackTask = await coordinator.startTask()
            progress.beginPhase("Unpacking…")
            for image in result.images {
                try await image.unpack(
                    platform: nil,
                    progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressHandler))
                try Task.checkCancellation()
            }
            await refresh()
        } catch is CancellationError {
            // User cancelled — not an error. defer sets importProgress = nil.
        } catch {
            guard importGeneration == generation else { return }
            guard !error.isCancellation else { return }
            lastError = .from("Failed to import image", error: error)
        }
    }

    /// Throwing, synchronous-completion pull for the MCP layer. Fetches and
    /// unpacks the reference (matching the UI path) but returns the resolved
    /// reference or throws, rather than driving the progress bar.
    func pullAndWait(reference: String) async throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw InputError("Image reference is empty")
        }
        let platform = currentLinuxPlatform
        let config = try await SystemConfig.load()
        let image = try await MirrorPull.fetch(
            originalReference: trimmed,
            platform: platform,
            config: config,
            progressUpdate: { _ in })
        try await image.unpack(platform: platform, progressUpdate: { _ in })
        await refresh()
        return trimmed
    }
}

/// One platform variant of an image, flattened for row display.
struct ImageArchEntry: Identifiable {
    /// The variant's manifest digest (full form), used as a stable identity.
    let id: String
    /// Human-facing architecture label, e.g. `arm64/v8` or `amd64`.
    let arch: String
    /// The 12-char short digest for display.
    let shortDigest: String
    /// The variant's on-disk size in bytes.
    let size: Int64

    init(variant: ImageResource.Variant) {
        self.id = variant.digest
        self.arch = ImageArchEntry.archLabel(variant.platform)
        self.shortDigest = ImageArchEntry.trimDigest(variant.digest)
        self.size = variant.size
    }

    /// `arch[/variant]`, matching the CLI's platform shorthand (e.g. `arm64/v8`).
    static func archLabel(_ platform: Platform) -> String {
        if let variant = platform.variant, !variant.isEmpty {
            return "\(platform.architecture)/\(variant)"
        }
        return platform.architecture
    }

    /// The hex portion of a digest, truncated to 12 chars (mirrors the CLI's
    /// `Utility.trimDigest`, kept local to avoid a cross-module dependency).
    static func trimDigest(_ digest: String) -> String {
        var hex = digest
        if let colonIndex = digest.firstIndex(of: ":") {
            hex = String(digest[digest.index(after: colonIndex)...])
        }
        return String(hex.prefix(12))
    }
}

/// One image reference (a single tag) within a repository group.
struct ImageTagRow: Identifiable {
    /// Unique per-tag identity: the full canonical reference (name:tag).
    /// Using the index digest alone would collide when two tags share the
    /// same manifest list — e.g. `alpine:3.24` and `alpine:latest` resolving
    /// to the same index — causing SwiftUI to render both rows with the
    /// same tag text.
    let id: String
    /// The underlying image resource, retained so the view can delete by `name`.
    let image: ContainerImage
    /// The tag portion of the reference (e.g. `latest`), or `<none>` if untagged.
    let tag: String
    /// The host-platform variant to show by default, if present.
    let current: ImageArchEntry?
    /// The remaining variants, shown under the "other architectures" expander.
    let others: [ImageArchEntry]
    /// Total on-disk size across all variants.
    let totalSize: Int64
}

/// A repository's images — one card in the grid.
struct ImageRepoGroup: Identifiable {
    var id: String { repository }
    let repository: String
    let tags: [ImageTagRow]

    /// Groups images by repository, picking each tag's host-platform variant as
    /// the default and ordering tags `latest`-first then lexically.
    static func group(_ images: [ContainerImage]) -> [ImageRepoGroup] {
        var byRepo: [String: [ImageTagRow]] = [:]
        for image in images {
            let parsed = ParsedImageReference(image.displayReference)
            byRepo[parsed.repository, default: []].append(makeRow(image, tag: parsed.tag))
        }
        return
            byRepo
            .map { repo, tags in
                ImageRepoGroup(repository: repo, tags: tags.sorted(by: tagOrder))
            }
            .sorted { $0.repository < $1.repository }
    }

    private static func makeRow(_ image: ContainerImage, tag: String?) -> ImageTagRow {
        // Drop attestation/referrer entries: OCI 1.1 indexes include manifest
        // descriptors with platform {architecture:"unknown", os:"unknown"} for
        // signatures/attestations - not runnable architectures.
        let entries = image.variants
            .map(ImageArchEntry.init(variant:))
            .filter { !$0.arch.isEmpty && $0.arch.lowercased() != "unknown" }
        let host = Platform.current
        // Prefer the exact host platform, then arm64, then amd64, then whatever
        // is first — so the default row is always runnable when possible.
        let currentIndex =
            entries.firstIndex { $0.arch == ImageArchEntry.archLabel(host) }
            ?? entries.firstIndex { $0.arch.hasPrefix("arm64") }
            ?? entries.firstIndex { $0.arch.hasPrefix("amd64") }
            ?? (entries.isEmpty ? nil : 0)

        var current: ImageArchEntry?
        var others = entries
        if let index = currentIndex {
            current = entries[index]
            others.remove(at: index)
        }
        return ImageTagRow(
            id: image.name,
            image: image,
            tag: tag ?? "<none>",
            current: current,
            others: others,
            totalSize: entries.reduce(0) { $0 + $1.size })
    }

    /// `latest` sorts first; everything else is ordered descending so newer-looking
    /// version tags float to the top.
    private static func tagOrder(_ lhs: ImageTagRow, _ rhs: ImageTagRow) -> Bool {
        if lhs.tag == "latest" { return true }
        if rhs.tag == "latest" { return false }
        return lhs.tag > rhs.tag
    }
}
