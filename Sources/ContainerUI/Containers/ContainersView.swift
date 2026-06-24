import ContainerResource
import SwiftUI

struct ContainersView: View {
    @Environment(ContainersModel.self) private var model
    @State private var pendingDelete: ContainerSnapshot?
    @State private var searchText = ""
    @State private var selectedID: ContainerSnapshot.ID?
    @State private var logsID: ContainerSnapshot.ID?
    @State private var showingCreate = false
    @State private var copyToast = false

    private var filteredContainers: [ContainerSnapshot] {
        guard !searchText.isEmpty else { return model.containers }
        let query = searchText.lowercased()
        return model.containers.filter {
            $0.id.lowercased().contains(query)
                || $0.configuration.image.reference.lowercased().contains(query)
        }
    }

    private var logsContainer: ContainerSnapshot? {
        guard let logsID else { return nil }
        return model.containers.first { $0.id == logsID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let progress = model.creating {
                InlineProgressBar(progress: progress, accent: Palette.containers,
                                  onCancel: { model.cancelCreate() })
            }
            if let error = model.lastError {
                ErrorBanner(
                    error: error,
                    onCopy: { showCopyToast() },
                    onDismiss: { model.clearError() })
            }
            if let error = model.pollError, !model.containers.isEmpty {
                ErrorBanner(message: error)
            }
            cardGrid
        }
        .overlay(alignment: .top) {
            if copyToast {
                copyToastView
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search containers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Create Container", systemImage: "plus")
                }
                .help("Create a new container")
                .disabled(model.creating != nil)
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showingCreate) {
            CreateContainerSheet(
                model: model,
                volumes: model.availableVolumes,
                networks: model.availableNetworks,
                onCreate: { spec in
                    model.startCreate(spec: spec)
                }
            )
            .task { await model.loadCreateResources() }
        }
        .sheet(
            isPresented: Binding(
                get: { logsContainer != nil },
                set: { if !$0 { logsID = nil } }
            )
        ) {
            if let container = logsContainer {
                ContainerDetailPanel(container: container, onClose: { logsID = nil })
                    .frame(width: 560, height: 620)
            }
        }
        .confirmationDialog(
            "Delete container?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { container in
            if container.status == .running {
                Button("Force Delete", role: .destructive) {
                    Task { await model.delete(container, force: true) }
                }
            } else {
                Button("Delete", role: .destructive) {
                    Task { await model.delete(container, force: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { container in
            Text(
                container.status == .running
                    ? "\(container.id) is running. It will be force deleted."
                    : "\(container.id) will be permanently removed.")
        }
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

    @ViewBuilder
    private var cardGrid: some View {
        if model.containers.isEmpty {
            VStack(spacing: 0) {
                if let pollError = model.pollError {
                    ContentUnavailableView {
                        Label("Can't reach the container service", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(pollError)
                    }
                } else {
                    ContentUnavailableView("No Containers", systemImage: "shippingbox")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if filteredContainers.isEmpty {
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
                    ForEach(filteredContainers) { container in
                        ContainerCard(
                            container: container,
                            isSelected: selectedID == container.id,
                            isBusy: model.busyItemIDs.contains(container.id),
                            onSelect: {
                                selectedID = (selectedID == container.id) ? nil : container.id
                            },
                            onStart: { Task { await model.start(container) } },
                            onStop: { Task { await model.stop(container) } },
                            onExec: { model.openShell(container) },
                            onLogs: { logsID = container.id },
                            onDelete: { pendingDelete = container },
                            onCopy: { _ in showCopyToast() }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}
