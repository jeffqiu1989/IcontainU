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

import ContainerResource
import SwiftUI

struct NetworksView: View {
    @State private var model = NetworksModel()
    @State private var searchText = ""
    @State private var selectedID: NetworkResource.ID?
    @State private var pendingDelete: NetworkResource?
    @State private var showCreateSheet = false

    private var filteredNetworks: [NetworkResource] {
        guard !searchText.isEmpty else { return model.networks }
        let query = searchText.lowercased()
        return model.networks.filter { $0.id.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }
            cardGrid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search networks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Network", systemImage: "plus")
                }
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkSheet { name, hostOnly, subnet in
                Task { await model.create(name: name, hostOnly: hostOnly, subnet: subnet) }
            }
        }
        .confirmationDialog(
            "Delete network?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { network in
            Button("Delete", role: .destructive) {
                Task { await model.delete(network) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { network in
            Text("\(network.name) will be permanently removed.")
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.networks.isEmpty {
            ContentUnavailableView("No Networks", systemImage: "network")
        } else if filteredNetworks.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14),
                    ],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(filteredNetworks) { network in
                        NetworkCard(
                            network: network,
                            isSelected: selectedID == network.id,
                            onSelect: {
                                selectedID = (selectedID == network.id) ? nil : network.id
                            },
                            onDelete: { pendingDelete = network }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Modal to create a network.
private struct CreateNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostOnly = false
    @State private var subnet = ""
    let onCreate: (String, Bool, String) -> Void

    var body: some View {
        FormSheet(
            icon: "network",
            iconColor: Palette.networks,
            title: "Create Network"
        ) {
            LabeledSection(label: "Name") {
                TextField("Network name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            LabeledSection(label: "Subnet") {
                TextField("Optional — e.g. 192.168.100.0/24", text: $subnet)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            LabeledSection(label: "Mode") {
                Toggle("Host-only (internal)", isOn: $hostOnly)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onCreate(value, hostOnly, subnet)
        dismiss()
    }
}
