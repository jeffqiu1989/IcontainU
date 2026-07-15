import ContainerResource
import SwiftUI
import UniformTypeIdentifiers

struct ImagesView: View {
    @Environment(ImagesModel.self) private var model
    @State private var pendingDelete: ContainerImage?
    @State private var showAddSheet = false
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
                    showAddSheet = true
                } label: {
                    Label("Add Image", systemImage: "plus")
                }
                .disabled(model.pull != nil || model.importProgress != nil)
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showAddSheet) {
            AddImageSheet(model: model)
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
        panel.title = String(localized: "Export Image")
        panel.nameFieldStringValue = Self.defaultExportFilename(for: image)
        panel.allowedContentTypes = [UTType(filenameExtension: "tar")].compactMap { $0 }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Pass the full canonical reference (e.g. docker.io/library/nginx:latest),
        // not the shortened displayReference — the backend matches the stored
        // canonical reference, same as delete.
        model.startExport(reference: image.name, outputURL: url)
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

/// Unified "add image" sheet: a segmented control picks the source - pull from a
/// registry (type a reference) or import a local OCI tar (folder picker). Replaces
/// the old two-button toolbar whose pull/import icons were hard to tell apart.
private struct AddImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ImagesModel
    @State private var mode: Mode = .pull
    @State private var reference = ""
    @State private var fileURL: URL?

    enum Mode: CaseIterable, Identifiable {
        case pull, importFile
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .pull: "Pull from registry"
            case .importFile: "Import from file"
            }
        }
    }

    var body: some View {
        FormSheet(
            icon: "opticaldiscdrive",
            iconColor: Palette.images,
            title: "Add Image",
            width: .wide,
            height: 240
        ) {
            // Centered segmented control (2 tabs).
            HStack {
                Spacer(minLength: 0)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer(minLength: 0)
            }

            // Fixed-height content area so switching tabs doesn't resize the sheet.
            // Three-column layout, horizontally centered: right-aligned label,
            // the control (text field / button), then an equal-width trailing
            // gap. The control column is the same size and position in both tabs.
            VStack(spacing: 6) {
                threeColumnRow {
                    Text(mode == .pull ? "Image" : "File")
                } control: {
                    switch mode {
                    case .pull:
                        TextField("hello-world:latest", text: $reference)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submit)
                    case .importFile:
                        Button {
                            chooseFile()
                        } label: {
                            Label("Choose File", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.blueOutline)
                    }
                }

                // Selected filename feedback under the control column (import only).
                if mode == .importFile, let fileURL {
                    threeColumnRow {
                        EmptyView()
                    } control: {
                        Text(fileURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 70, alignment: .top)
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(actionLabel, action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
        }
    }

    /// Three columns, horizontally centered: a right-aligned label column, the
    /// control column (the same width/position in both tabs), and an equal-width
    /// trailing gap so the row is visually centered.
    @ViewBuilder
    private func threeColumnRow<L: View, C: View>(
        @ViewBuilder label: () -> L, @ViewBuilder control: () -> C
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Spacer(minLength: 0)
            label()
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 60, alignment: .trailing)
            control()
                .frame(width: 220)
            Color.clear.frame(width: 60, height: 0)
            Spacer(minLength: 0)
        }
    }

    private var actionLabel: LocalizedStringKey {
        mode == .pull ? "Pull" : "Import"
    }

    private var canSubmit: Bool {
        switch mode {
        case .pull: !reference.trimmingCharacters(in: .whitespaces).isEmpty
        case .importFile: fileURL != nil
        }
    }

    private func submit() {
        switch mode {
        case .pull:
            let ref = reference.trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { return }
            model.startPullImage(reference: ref)
        case .importFile:
            guard let fileURL else { return }
            model.startImport(inputURL: fileURL)
        }
        dismiss()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tar")].compactMap { $0 }
        if panel.runModal() == .OK { fileURL = panel.url }
    }
}
