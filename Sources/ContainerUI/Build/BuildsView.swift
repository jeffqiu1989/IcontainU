import SwiftUI

/// The Build section: a grid of persisted build-config cards (one per
/// Dockerfile + context + tags) plus the active build's progress. Builder state
/// isn't shown here - check the builder container from the Containers page.
/// Logs open on demand in a sheet (LogConsoleView - bounded, batched,
/// follow-at-bottom) instead of rendering inline, so a chatty build never
/// freezes the UI.
struct BuildsView: View {
    @Environment(BuildsModel.self) private var model
    /// What the build sheet is presenting: a fresh config (.new) or an existing
    /// one to edit. Used as the sheet item (rather than a Bool + separate record)
    /// so the presented record can't be stale-captured - the first Edit tap used
    /// to show an empty form because the sheet closure held the previous (nil)
    /// value of a separate `editingRecord` state.
    @State private var buildSheet: BuildSheetTarget?
    /// Config whose log sheet is open.
    @State private var logTarget: LogTarget?
    @State private var pendingDelete: BuildConfigRecord?
    @State private var searchText = ""

    private enum BuildSheetTarget: Identifiable {
        case new
        case edit(BuildConfigRecord)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let r): "edit-\(r.name)"
            }
        }
        var existing: BuildConfigRecord? {
            if case .edit(let r) = self { return r }
            return nil
        }
    }

    private struct LogTarget: Identifiable {
        let name: String
        var id: String { name }
    }

    private var filteredConfigs: [BuildConfigView] {
        guard !searchText.isEmpty else { return model.configs }
        let query = searchText.lowercased()
        return model.configs.filter { config in
            config.record.name.lowercased().contains(query)
                || config.record.tags.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let active = model.activeBuild {
                InlineProgressBar(
                    progress: active.progress, accent: Palette.build,
                    onCancel: { model.cancelBuild() })
            }
            if let error = model.lastError {
                ErrorBanner(error: error, onDismiss: { model.clearError() })
            }
            cardGrid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search builds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    buildSheet = .new
                } label: {
                    Label("New Build", systemImage: "plus")
                }
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(item: $buildSheet) { target in
            CreateBuildSheet(
                existing: target.existing,
                takenNames: Set(model.configs.map(\.record.name)),
                onSave: { record, buildNow in
                    model.saveConfig(record)
                    if buildNow {
                        model.startBuild(record: record)
                    }
                })
        }
        .sheet(item: $logTarget) { target in
            logSheet(configName: target.name)
        }
        .confirmationDialog(
            "Delete build config?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { record in
            Button("Delete", role: .destructive) {
                model.removeConfig(name: record.name)
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("\"\(record.name)\" will be removed. Built images are kept.")
        }
    }

    // MARK: - Card grid

    @ViewBuilder
    private var cardGrid: some View {
        if model.configs.isEmpty {
            ContentUnavailableView("No Builds", systemImage: "hammer")
                .frame(maxHeight: .infinity, alignment: .top)
        } else if filteredConfigs.isEmpty {
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
                    ForEach(filteredConfigs) { config in
                        BuildConfigCard(
                            config: config,
                            buildDisabled: model.isBuilding,
                            onBuild: { model.startBuild(record: config.record) },
                            onViewLog: { logTarget = LogTarget(name: config.record.name) },
                            onEdit: {
                                buildSheet = .edit(config.record)
                            },
                            onDelete: { pendingDelete = config.record })
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Log sheet

    private func logSheet(configName: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(Palette.build)
                Text("Build log - \(configName)")
                    .font(.headline)
                Spacer()
                if model.activeBuild?.configName == configName {
                    ProgressView().controlSize(.small)
                }
                Button("Close") { logTarget = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            LogConsoleView(buffer: model.logBuffer(for: configName))
        }
        .frame(width: 720, height: 480)
    }
}
