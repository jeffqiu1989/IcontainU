import ContainerResource
import SwiftUI

struct ImagesView: View {
    @Environment(ImagesModel.self) private var model
    @State private var pendingDelete: ContainerImage?
    @State private var showPullSheet = false
    @State private var searchText = ""

    /// Repository groups matching the search query (by repo name or any tag).
    private var filteredGroups: [ImageRepoGroup] {
        let groups = model.repoGroups
        guard !searchText.isEmpty else { return groups }
        let query = searchText.lowercased()
        return groups.compactMap { group in
            if group.repository.lowercased().contains(query) { return group }
            let tags = group.tags.filter { $0.tag.lowercased().contains(query) }
            return tags.isEmpty ? nil : ImageRepoGroup(repository: group.repository, tags: tags)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pull = model.pull {
                InlineProgressBar(progress: pull, accent: Palette.images)
            }
            if let error = model.lastError {
                ErrorBanner(error: error, onDismiss: { model.clearError() })
            }
            if let error = model.pollError, !model.images.isEmpty {
                ErrorBanner(message: error)
            }
            cardGrid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search images")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPullSheet = true
                } label: {
                    Label("Pull Image", systemImage: "arrow.down.circle")
                }
                .disabled(model.pull != nil)
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageSheet { reference in
                Task { await model.pullImage(reference: reference) }
            }
        }
        .confirmationDialog(
            "Delete image?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { image in
            Button("Delete", role: .destructive) {
                Task { await model.delete(image) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { image in
            Text("\(image.displayReference) will be removed.")
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.images.isEmpty {
            VStack(spacing: 0) {
                if let pollError = model.pollError {
                    ContentUnavailableView {
                        Label("Can't reach the container service", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(pollError)
                    }
                } else {
                    ContentUnavailableView("No Images", systemImage: "opticaldiscdrive")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if filteredGroups.isEmpty {
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
                    ForEach(filteredGroups) { group in
                        ImageRepoCard(
                            group: group,
                            onDelete: { pendingDelete = $0 }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Modal to enter an image reference to pull.
private struct PullImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    let onPull: (String) -> Void

    var body: some View {
        FormSheet(
            icon: "opticaldiscdrive",
            iconColor: Palette.images,
            title: "Pull Image"
        ) {
            LabeledSection(label: "Reference") {
                TextField("e.g. alpine:3.22", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Pull") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let value = reference.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onPull(value)
        dismiss()
    }
}
