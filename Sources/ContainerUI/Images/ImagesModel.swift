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
            // Delete by the full reference (e.g. docker.io/library/nginx:latest),
            // not the shortened displayReference — the backend matches the stored
            // canonical reference, so a denormalized name would not be found.
            try await ClientImage.delete(reference: image.name, garbageCollect: true)
            await refresh()
        } catch {
            lastError = OperationError(
                title: "Failed to delete image", detail: error.localizedDescription)
        }
    }

    /// The host's Linux platform (e.g. linux/arm64 on Apple silicon). Pulling and
    /// unpacking only this platform avoids fetching other architectures' variants,
    /// which cannot run on this machine. (container defaults to all platforms.)
    private var currentLinuxPlatform: Platform? {
        try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
    }

    /// Pulls a reference and unpacks it (matching the CLI), reporting progress.
    ///
    /// Fetch and unpack are coordinated as two distinct phases: a
    /// `ProgressTaskCoordinator` makes the fetch task non-current the instant
    /// unpack begins, so any late fetch events are dropped instead of bumping
    /// the unpack bar — the same technique the CLI uses to keep progress stable.
    func pullImage(reference: String) async {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        lastError = nil
        let platform = currentLinuxPlatform
        let viaMirror = RegistryMirrorStore.shared.rewrite(trimmed) != trimmed

        var progress = OperationProgress()
        progress.beginPhase(viaMirror ? "Pulling \(trimmed) via mirror…" : "Pulling \(trimmed)…")
        pull = progress
        defer { pull = nil }

        let coordinator = ProgressTaskCoordinator()
        defer { Task { await coordinator.finish() } }

        do {
            let config = try await SystemConfig.load()
            // Pull through any configured mirror, then retag to the canonical
            // reference so the local image is mirror-free.
            let fetchTask = await coordinator.startTask()
            let image = try await MirrorPull.pull(
                originalReference: trimmed,
                platform: platform,
                config: config,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressHandler))

            let unpackTask = await coordinator.startTask()
            pull?.beginPhase("Unpacking…")
            try await image.unpack(
                platform: platform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressHandler))
            await refresh()
        } catch {
            lastError = OperationError(
                title: "Failed to pull image", detail: error.localizedDescription)
        }
    }

    /// Folds the progress event stream into the shared `OperationProgress` state.
    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyProgress(events)
        }
    }

    private func applyProgress(_ events: [ProgressUpdateEvent]) {
        guard pull != nil else { return }
        pull?.apply(events)
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
    /// The image's index digest — stable identity for the row.
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
        let entries = image.variants.map(ImageArchEntry.init(variant:))
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
            id: image.id,
            image: image,
            tag: tag ?? "<none>",
            current: current,
            others: others,
            totalSize: image.totalSize)
    }

    /// `latest` sorts first; everything else is ordered descending so newer-looking
    /// version tags float to the top.
    private static func tagOrder(_ lhs: ImageTagRow, _ rhs: ImageTagRow) -> Bool {
        if lhs.tag == "latest" { return true }
        if rhs.tag == "latest" { return false }
        return lhs.tag > rhs.tag
    }
}
