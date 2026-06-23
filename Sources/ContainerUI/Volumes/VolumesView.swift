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
            if let error = model.pollError, !model.volumes.isEmpty {
                ErrorBanner(message: error)
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
            VStack(spacing: 0) {
                if let pollError = model.pollError {
                    ContentUnavailableView {
                        Label("Can't reach the container service", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(pollError)
                    }
                } else {
                    ContentUnavailableView("No Volumes", systemImage: "externaldrive")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if filteredVolumes.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxHeight: .infinity, alignment: .top)
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
    /// Size in gigabytes — digits only; the `G` unit is shown as a fixed suffix.
    @State private var size = "50"
    let onCreate: (String, String) -> Void

    /// A blank size falls back to the server default; otherwise it must be a
    /// positive integer number of gigabytes.
    private var sizeValid: Bool {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let value = Int(trimmed) else { return false }
        return value > 0
    }

    /// The size passed to the server: `<n>G`, or empty to use the default.
    private var sizeString: String {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "\(trimmed)G"
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
                HStack(spacing: 8) {
                    TextField("50", text: $size)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: size) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { size = digits }
                        }
                        .onSubmit(submit)
                    Text("G")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
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
        onCreate(value, sizeString)
        dismiss()
    }
}
