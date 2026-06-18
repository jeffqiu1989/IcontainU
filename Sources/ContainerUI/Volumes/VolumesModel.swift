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
import Foundation
import Observation

@Observable
@MainActor
final class VolumesModel {
    private(set) var volumes: [VolumeConfiguration] = []
    private(set) var pollError: String?
    private(set) var lastError: OperationError?

    func clearError() { lastError = nil }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        do {
            volumes = try await ClientVolume.list().sorted { $0.name < $1.name }
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func create(name: String, size: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        lastError = nil
        do {
            // A blank size uses the server default (512GB). A non-empty value is
            // passed through driverOpts["size"], mirroring the CLI's `--size`; the
            // server parses suffixes (K/M/G/T/P) and reports a bad value as an error.
            let trimmedSize = size.trimmingCharacters(in: .whitespaces)
            let driverOpts = trimmedSize.isEmpty ? [:] : ["size": trimmedSize]
            _ = try await ClientVolume.create(name: trimmed, driverOpts: driverOpts)
            await refresh()
        } catch {
            lastError = OperationError(title: "创建卷失败", detail: error.localizedDescription)
        }
    }

    func delete(_ volume: VolumeConfiguration) async {
        lastError = nil
        do {
            try await ClientVolume.delete(name: volume.name)
            await refresh()
        } catch {
            lastError = OperationError(title: "删除卷失败", detail: error.localizedDescription)
        }
    }
}
