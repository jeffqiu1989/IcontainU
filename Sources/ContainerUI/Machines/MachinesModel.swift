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
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Observation
import TerminalProgress

@Observable
@MainActor
final class MachinesModel {
    /// Progress of an in-flight machine creation (image fetch + unpack).
    struct CreateProgress {
        var description: String = "Preparing…"
        var currentSize: Int64 = 0
        var totalSize: Int64 = 0

        var fraction: Double? {
            guard totalSize > 0 else { return nil }
            return min(1.0, Double(currentSize) / Double(totalSize))
        }
    }

    private(set) var machines: [MachineSnapshot] = []
    private(set) var defaultID: String?
    private(set) var errorMessage: String?
    private(set) var creating: CreateProgress?

    private let client = MachineClient()

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            async let list = client.list()
            async let def = client.getDefault()
            machines = try await list
            defaultID = try await def
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func boot(_ machine: MachineSnapshot) async {
        do {
            _ = try await client.boot(id: machine.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ machine: MachineSnapshot) async {
        do {
            try await client.stop(id: machine.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Open an interactive shell in the machine via the system Terminal.
    /// `machine run` boots the machine first if it is stopped.
    func openShell(_ machine: MachineSnapshot) {
        do {
            try TerminalLauncher.runInMachine(id: machine.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ machine: MachineSnapshot) async {
        do {
            try await client.delete(id: machine.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Create a machine from an image. Honors registry mirrors (with retag back to
    /// the canonical reference). Assembles the config inline rather than via the
    /// CLI's `machineConfigFromFlags`, whose ArgumentParser `Flags` types crash
    /// when constructed outside of command-line parsing.
    func create(
        image: String,
        name: String?,
        cpus: Int?,
        memory: String?,
        homeMount: String?,
        setAsDefault: Bool,
        noBoot: Bool
    ) async {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return }

        creating = CreateProgress()
        defer { creating = nil }

        do {
            let config = try await SystemConfig.load()

            guard let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)") else {
                throw ContainerizationError(.invalidArgument, message: "could not resolve host platform")
            }

            // Boot config: start from system defaults, override only provided fields.
            let bootConfig = try config.machine.with(
                [
                    "cpus": cpus.map { "\($0)" },
                    "memory": memory,
                    "home-mount": homeMount,
                ].compactMapValues { $0 }
            )

            // Fetch the image (mirror-aware; retagged to canonical reference).
            creating?.description = "Fetching image…"
            let img = try await MirrorPull.pull(
                originalReference: trimmedImage,
                platform: platform,
                config: config,
                progressUpdate: progressHandler)

            // Unpack into a create snapshot before use.
            creating?.description = "Unpacking image…"
            creating?.currentSize = 0
            creating?.totalSize = 0
            _ = try await img.getCreateSnapshot(platform: platform, progressUpdate: progressHandler)

            // Determine the machine id (auto-derive from the canonical image when blank).
            let id = try machineID(name: name, image: img.reference)
            try Utility.validEntityName(id)

            let userSetup = UserSetup(username: NSUserName(), uid: getuid(), gid: getgid())
            let machineConfig = try MachineConfiguration(
                id: id,
                image: img.description,
                platform: platform,
                userSetup: userSetup)

            // resources is optional; the machine setup artifact is fetched by an
            // internal CLI helper not available here. container falls back to its
            // built-in user provisioning when absent.
            try await client.create(configuration: machineConfig, resources: nil, bootConfig: bootConfig)

            if setAsDefault {
                try await client.setDefault(id: id)
            }
            if !noBoot {
                _ = try await client.boot(id: id)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Mirror the CLI's id derivation: explicit name, else `<imageName>-<tag>`.
    private func machineID(name: String?, image: String) throws -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        let reference = try Reference.parse(image)
        reference.normalize()
        let imageName = reference.name.components(separatedBy: "/").last ?? reference.name
        let suffix = reference.tag ?? reference.digest ?? "latest"
        return "\(imageName)-\(suffix)"
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
