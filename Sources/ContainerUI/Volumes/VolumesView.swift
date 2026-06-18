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

struct VolumesView: View {
    @Environment(VolumesModel.self) private var model
    @State private var searchText = ""
    @State private var selectedID: VolumeConfiguration.ID?
    @State private var pendingDelete: VolumeConfiguration?
    @State private var showCreateSheet = false

    private var filteredVolumes: [VolumeConfiguration] {
        guard !searchText.isEmpty else { return model.volumes }
        let query = searchText.lowercased()
        return model.volumes.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                ErrorBanner(error: error, onDismiss: { model.clearError() })
            }
            cardGrid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search volumes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Volume", systemImage: "plus")
                }
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeSheet { name, size in
                Task { await model.create(name: name, size: size) }
            }
        }
        .confirmationDialog(
            "Delete volume?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { volume in
            Button("Delete", role: .destructive) {
                Task { await model.delete(volume) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { volume in
            Text("\(volume.name) and its data will be permanently removed.")
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.volumes.isEmpty {
            ContentUnavailableView("No Volumes", systemImage: "externaldrive")
        } else if filteredVolumes.isEmpty {
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
                    ForEach(filteredVolumes) { volume in
                        VolumeCard(
                            volume: volume,
                            isSelected: selectedID == volume.id,
                            onSelect: {
                                selectedID = (selectedID == volume.id) ? nil : volume.id
                            },
                            onDelete: { pendingDelete = volume }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Modal to create a named volume.
private struct CreateVolumeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = ""
    let onCreate: (String, String) -> Void

    /// Loose client-side check for an obviously malformed size; the server does
    /// the authoritative parsing (and enforces the 1 MiB minimum / 512 G default).
    private var sizeValid: Bool {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.range(of: #"^\d+(\.\d+)?\s*[KMGTPkmgtp]?[iI]?[bB]?$"#, options: .regularExpression) != nil
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && sizeValid
    }

    var body: some View {
        FormSheet(
            icon: "externaldrive",
            iconColor: Palette.volumes,
            title: "Create Volume"
        ) {
            LabeledSection(label: "Name") {
                TextField("Volume name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            LabeledSection(label: "Size") {
                TextField("Optional — e.g. 10G (default 512G)", text: $size)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, sizeValid else { return }
        onCreate(value, size.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
