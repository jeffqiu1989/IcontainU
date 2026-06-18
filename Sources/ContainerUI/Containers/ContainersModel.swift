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
final class ContainersModel {
    /// Progress of an in-flight container creation (image fetch + unpack).
    struct CreateProgress {
        var description: String = "Preparing…"
        var currentSize: Int64 = 0
        var totalSize: Int64 = 0

        var fraction: Double? {
            guard totalSize > 0 else { return nil }
            return min(1.0, Double(currentSize) / Double(totalSize))
        }
    }

    private(set) var containers: [ContainerSnapshot] = []
    private(set) var errorMessage: String?
    private(set) var creating: CreateProgress?

    /// Resources offered in the create form's volume / network pickers.
    private(set) var availableVolumes: [VolumeConfiguration] = []
    private(set) var availableNetworks: [NetworkResource] = []

    private let client = ContainerClient()
    private let networkClient = NetworkClient()

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            // No status filter → include stopped containers (otherwise a container
            // vanishes from the list the moment it stops). Exclude machines, which
            // are containers under the hood but managed in their own tab.
            let filters = ContainerListFilters.all.withoutMachines()
            containers = try await client.list(filters: filters)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Detached start: bootstrap with no stdio attached, then start the process.
    func start(_ container: ContainerSnapshot) async {
        do {
            let process = try await client.bootstrap(id: container.id, stdio: [nil, nil, nil])
            try await process.start()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ container: ContainerSnapshot) async {
        do {
            try await client.stop(id: container.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ container: ContainerSnapshot, force: Bool) async {
        do {
            try await client.delete(id: container.id, force: force)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Open an interactive shell in the container via the system Terminal.
    func openShell(_ container: ContainerSnapshot) {
        do {
            try TerminalLauncher.execInContainer(id: container.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Analyze an image to pre-fill the create form. Best effort: returns an empty
    /// metadata on failure and surfaces the error so the user knows why.
    func analyze(image: String) async -> ImageMetadata {
        let trimmed = image.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        else { return ImageMetadata() }
        do {
            let config = try await SystemConfig.load()
            let img = try await ClientImage.get(reference: trimmed, containerSystemConfig: config)
            let metadata = try await ImageInspector.analyze(image: img, platform: platform)
            return metadata
        } catch {
            errorMessage = "Image analysis failed: \(error.localizedDescription)"
            return ImageMetadata()
        }
    }

    /// Load the volumes and networks offered in the create form's pickers.
    /// Best effort: a failure here just leaves the pickers with built-in options.
    func loadCreateResources() async {
        async let volumes = try? ClientVolume.list()
        async let networks = try? networkClient.list()
        availableVolumes = (await volumes ?? []).sorted { $0.name < $1.name }
        availableNetworks = await networks ?? []
    }

    func create(spec: ContainerCreateSpec) async {
        creating = CreateProgress()
        defer { creating = nil }
        do {
            let id = try await ContainerCreateEngine.create(spec: spec, progressUpdate: progressHandler)
            await refresh()
            await reportIfStopped(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A freshly created container may already be stopped — and that is not
    /// necessarily an error. A shell base image exits immediately with no command,
    /// a one-shot job exits when its work is done, and a misconfigured run fails.
    /// Detached start has no exit code to tell these apart, so stay neutral and
    /// point the user at the logs (full detail is also in the `swift run` console).
    private func reportIfStopped(id: String) async {
        try? await Task.sleep(for: .seconds(2))
        await refresh()
        guard let container = containers.first(where: { $0.id == id }) else { return }
        if container.status == .stopped {
            errorMessage =
                "Container \"\(id)\" has already stopped. "
                + "If that wasn't expected, open it and check the Logs tab."
        }
    }

    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyProgress(events)
        }
    }

    private func applyProgress(_ events: [ProgressUpdateEvent]) {
        guard creating != nil else { return }
        for event in events {
            switch event {
            case .setDescription(let value), .setSubDescription(let value):
                creating?.description = value
            case .setTotalSize(let value): creating?.totalSize = value
            case .addTotalSize(let value): creating?.totalSize += value
            case .setSize(let value): creating?.currentSize = value
            case .addSize(let value): creating?.currentSize += value
            default: break
            }
        }
    }
}
