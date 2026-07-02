import SwiftUI

struct ComposeView: View {
    @Environment(ComposeModel.self) private var model
    @State private var showingImport = false
    @State private var pendingDown: ComposeProjectView?
    @State private var pendingRemove: ComposeProjectView?
    @State private var pendingLogs: LogsTarget?
    @State private var copyToast = false

    /// Identifiable wrapper so the logs sheet can bind via `.sheet(item:)`.
    private struct LogsTarget: Identifiable { let id: String }

    var body: some View {
        VStack(spacing: 0) {
            if let progress = model.upping {
                InlineProgressBar(progress: progress, accent: Palette.compose,
                                  onCancel: { model.cancelUp() })
            }
            if let error = model.lastError {
                ErrorBanner(
                    error: error,
                    onCopy: { showCopyToast() },
                    onDismiss: { model.clearError() })
            }
            if let error = model.pollError, !model.projects.isEmpty {
                ErrorBanner(message: error)
            }
            cardGrid
        }
        .overlay(alignment: .top) {
            if copyToast { copyToastView }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImport = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .help("Import a compose file")
                .disabled(model.upping != nil)
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportComposeSheet(model: model)
        }
        .sheet(item: $pendingLogs) { target in
            composeLogsSheet(containerID: target.id)
        }
        .confirmationDialog(
            "Bring project down?",
            isPresented: Binding(
                get: { pendingDown != nil },
                set: { if !$0 { pendingDown = nil } }
            ),
            presenting: pendingDown
        ) { project in
            Button("Down (keep volumes)", role: .destructive) {
                Task { await model.down(project: project.name, removeVolumes: false, removeNetworks: true) }
            }
            Button("Down + delete volumes", role: .destructive) {
                Task { await model.down(project: project.name, removeVolumes: true, removeNetworks: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(
                "Stop and delete all containers in \"\(project.name)\". "
                    + "Volumes hold your data — keep them unless you want a clean slate.")
        }
        .confirmationDialog(
            "Remove project?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            presenting: pendingRemove
        ) { project in
            Button("Remove everything", role: .destructive) {
                Task { await model.remove(project: project.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(
                "\"\(project.name)\" and all its containers, networks and volumes will be "
                    + "permanently removed, along with the saved compose file.")
        }
    }

    /// A logs sheet wrapping the existing single-container `ContainerLogsTab`, so
    /// the user can read a service's output without leaving the Compose tab.
    private func composeLogsSheet(containerID: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(containerID, systemImage: "text.alignleft")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Done") { pendingLogs = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ContainerLogsTab(containerID: containerID)
        }
        .frame(width: 760, height: 520)
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.projects.isEmpty {
            if let pollError = model.pollError {
                ContentUnavailableView {
                    Label("Can't reach the container service", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(pollError)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Import a compose file to bring up a group of services together.")
                } actions: {
                    Button("New Project") { showingImport = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.compose)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
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
                    ForEach(model.projects) { project in
                        ComposeProjectCard(
                            project: project,
                            isBusy: model.busyProjects.contains(project.name),
                            isUpping: model.uppingProject == project.name,
                            hostsDegraded: model.hostsDegraded.contains(project.name),
                            onUp: { up(project) },
                            onDown: { pendingDown = project },
                            onRemove: { pendingRemove = project },
                            onServiceLogs: { pendingLogs = LogsTarget(id: $0) })
                    }
                }
                .padding(16)
            }
        }
    }

    /// Re-Up a stored project from its saved record.
    private func up(_ project: ComposeProjectView) {
        guard let record = ComposeProjectStore.shared.record(for: project.name) else { return }
        model.startUp(record: record)
    }

    private var copyToastView: some View {
        Text("Copied")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.2), lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func showCopyToast() {
        withAnimation(.easeOut(duration: 0.2)) { copyToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeIn(duration: 0.2)) { copyToast = false }
        }
    }
}
