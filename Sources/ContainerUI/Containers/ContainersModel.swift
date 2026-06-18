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
    private(set) var containers: [ContainerSnapshot] = []
    /// Transient list-fetch failure: managed entirely by `refresh`.
    private(set) var pollError: String?
    /// Failure (or notice) from an explicit action: never cleared by polling.
    private(set) var lastError: OperationError?
    private(set) var creating: OperationProgress?
    private(set) var busyItemIDs: Set<String> = []

    func clearError() { lastError = nil }

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
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    /// Detached start: bootstrap with no stdio attached, then start the process.
    func start(_ container: ContainerSnapshot) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            let process = try await client.bootstrap(id: container.id, stdio: [nil, nil, nil])
            try await process.start()
            await refresh()
        } catch {
            lastError = OperationError(title: "启动容器失败", detail: error.localizedDescription)
        }
    }

    func stop(_ container: ContainerSnapshot) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            try await client.stop(id: container.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "停止容器失败", detail: error.localizedDescription)
        }
    }

    func delete(_ container: ContainerSnapshot, force: Bool) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            try await client.delete(id: container.id, force: force)
            await refresh()
        } catch {
            lastError = OperationError(title: "删除容器失败", detail: error.localizedDescription)
        }
    }

    /// Open an interactive shell in the container via the system Terminal.
    func openShell(_ container: ContainerSnapshot) {
        lastError = nil
        do {
            try TerminalLauncher.execInContainer(id: container.id)
        } catch {
            lastError = OperationError(title: "打开终端失败", detail: error.localizedDescription)
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
            lastError = OperationError(title: "镜像分析失败", detail: error.localizedDescription)
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

    /// Create + start a container. Image fetch and container prepare are run as
    /// two coordinated phases (see `pullImage` for the rationale): late events
    /// from the finished fetch phase are dropped instead of disturbing the
    /// prepare bar, and each phase is labeled explicitly.
    func create(spec: ContainerCreateSpec) async {
        lastError = nil
        creating = OperationProgress()
        defer { creating = nil }

        let coordinator = ProgressTaskCoordinator()
        do {
            let id = try await ContainerCreateEngine.create(spec: spec) { [weak self] label in
                await self?.beginCreatePhase(label, coordinator: coordinator) ?? { _ in }
            }
            await coordinator.finish()
            await refresh()
            await reportIfStopped(id: id)
        } catch {
            await coordinator.finish()
            lastError = OperationError(title: "创建容器失败", detail: error.localizedDescription)
        }
    }

    /// Open a new coordinator task for a create phase, relabel the progress, and
    /// return a handler that only forwards while this phase is current.
    private func beginCreatePhase(
        _ label: String, coordinator: ProgressTaskCoordinator
    ) async -> ProgressUpdateHandler {
        let task = await coordinator.startTask()
        creating?.beginPhase(label)
        return ProgressTaskCoordinator.handler(for: task, from: progressHandler)
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
            lastError = OperationError(
                title: "容器已停止",
                detail: "Container \"\(id)\" has already stopped. "
                    + "If that wasn't expected, open it and check the Logs tab.")
        }
    }

    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyProgress(events)
        }
    }

    private func applyProgress(_ events: [ProgressUpdateEvent]) {
        guard creating != nil else { return }
        creating?.apply(events)
    }
}
