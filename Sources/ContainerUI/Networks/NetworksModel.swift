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
import ContainerizationExtras
import Foundation
import Observation

@Observable
@MainActor
final class NetworksModel {
    private(set) var networks: [NetworkResource] = []
    private(set) var pollError: String?
    private(set) var lastError: OperationError?

    func clearError() { lastError = nil }

    private let client = NetworkClient()

    /// Default plugin used by the CLI for `network create`.
    private static let defaultPlugin = "container-network-vmnet"

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        do {
            networks = try await client.list().sorted { $0.id < $1.id }
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func create(name: String, hostOnly: Bool, subnet: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        lastError = nil
        do {
            // A blank subnet lets the plugin auto-allocate. A non-empty value is
            // validated by constructing a CIDRv4, which throws on bad input — the
            // error then surfaces in the banner instead of failing server-side.
            let trimmedSubnet = subnet.trimmingCharacters(in: .whitespaces)
            let ipv4Subnet = try trimmedSubnet.isEmpty ? nil : CIDRv4(trimmedSubnet)
            let config = try NetworkConfiguration(
                name: trimmed,
                mode: hostOnly ? .hostOnly : .nat,
                ipv4Subnet: ipv4Subnet,
                plugin: Self.defaultPlugin)
            _ = try await client.create(configuration: config)
            await refresh()
        } catch {
            lastError = OperationError(title: "创建网络失败", detail: error.localizedDescription)
        }
    }

    func delete(_ network: NetworkResource) async {
        lastError = nil
        do {
            try await client.delete(id: network.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "删除网络失败", detail: error.localizedDescription)
        }
    }
}
