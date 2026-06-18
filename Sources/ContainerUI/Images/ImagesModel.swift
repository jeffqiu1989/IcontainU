//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Observation
import TerminalProgress

@Observable
@MainActor
final class ImagesModel {
    /// Progress of an in-flight pull, surfaced to the UI.
    struct PullProgress {
        var description: String = "Preparing…"
        var currentSize: Int64 = 0
        var totalSize: Int64 = 0

        var fraction: Double? {
            guard totalSize > 0 else { return nil }
            return min(1.0, Double(currentSize) / Double(totalSize))
        }
    }

    private(set) var images: [ContainerImage] = []
    private(set) var errorMessage: String?
    private(set) var pull: PullProgress?

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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ image: ContainerImage) async {
        do {
            // Delete by the full reference (e.g. docker.io/library/nginx:latest),
            // not the shortened displayReference — the backend matches the stored
            // canonical reference, so a denormalized name would not be found.
            try await ClientImage.delete(reference: image.name, garbageCollect: true)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The host's Linux platform (e.g. linux/arm64 on Apple silicon). Pulling and
    /// unpacking only this platform avoids fetching other architectures' variants,
    /// which cannot run on this machine. (container defaults to all platforms.)
    private var currentLinuxPlatform: Platform? {
        try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
    }

    /// Pulls a reference and unpacks it (matching the CLI), reporting progress.
    func pullImage(reference: String) async {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let platform = currentLinuxPlatform
        let viaMirror = RegistryMirrorStore.shared.rewrite(trimmed) != trimmed

        pull = PullProgress()
        if viaMirror {
            pull?.description = "Pulling via mirror…"
        }
        defer { pull = nil }

        do {
            let config = try await SystemConfig.load()
            // Pull through any configured mirror, then retag to the canonical
            // reference so the local image is mirror-free.
            let image = try await MirrorPull.pull(
                originalReference: trimmed,
                platform: platform,
                config: config,
                progressUpdate: progressHandler)
            pull?.description = "Unpacking…"
            pull?.currentSize = 0
            pull?.totalSize = 0
            try await image.unpack(platform: platform, progressUpdate: progressHandler)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Translates the progress event stream into the simple PullProgress state.
    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.apply(events)
        }
    }

    private func apply(_ events: [ProgressUpdateEvent]) {
        guard pull != nil else { return }
        for event in events {
            switch event {
            case .setDescription(let value), .setSubDescription(let value):
                pull?.description = value
            case .setTotalSize(let value):
                pull?.totalSize = value
            case .addTotalSize(let value):
                pull?.totalSize += value
            case .setSize(let value):
                pull?.currentSize = value
            case .addSize(let value):
                pull?.currentSize += value
            default:
                break
            }
        }
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
