import ContainerResource
import SwiftUI
import UniformTypeIdentifiers

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
                InlineProgressBar(progress: pull, accent: Palette.images,
                                  onCancel: { model.cancelPull() })
            }
            if let export = model.export {
                InlineProgressBar(progress: export, accent: Palette.images,
                                  onCancel: { model.cancelExport() })
            }
            if let progress = model.importProgress {
                InlineProgressBar(progress: progress, accent: Palette.images,
                                  onCancel: { model.cancelImport() })
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importImage()
                } label: {
                    Label("Import Image", systemImage: "square.and.arrow.down")
                }
                .disabled(model.importProgress != nil)
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageSheet { reference in
                model.startPullImage(reference: reference)
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
                            onDelete: { pendingDelete = $0 },
                            onExport: { exportImage($0) },
                            exportDisabled: model.export != nil
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Export / Import

    /// Opens a save panel and exports the given image as an OCI tar archive.
    private func exportImage(_ image: ContainerImage) {
        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.nameFieldStringValue = Self.defaultExportFilename(for: image)
        panel.allowedContentTypes = [UTType(filenameExtension: "tar")].compactMap { $0 }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Pass the full canonical reference (e.g. docker.io/library/nginx:latest),
        // not the shortened displayReference — the backend matches the stored
        // canonical reference, same as delete.
        model.startExport(reference: image.name, outputURL: url)
    }

    /// Opens a file panel and imports images from an OCI tar archive.
    private func importImage() {
        let panel = NSOpenPanel()
        panel.title = "Import Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tar")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.startImport(inputURL: url)
    }

    /// A safe filesystem name for an exported archive, e.g.
    /// `nginx:latest` → `nginx_latest.tar`.
    private static func defaultExportFilename(for image: ContainerImage) -> String {
        let parsed = ParsedImageReference(image.displayReference)
        var name = parsed.repository
        if let tag = parsed.tag, !tag.isEmpty {
            name += "_\(tag)"
        }
        // Drop anything that's unsafe in a filename (path separators, colons,
        // ports from a registry host, etc.).
        let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|@ ")
        let sanitized = name.unicodeScalars
            .map { disallowed.contains($0) ? "_" : String($0) }
            .joined()
        return "\(sanitized).tar"
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
