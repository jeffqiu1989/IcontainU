import ContainerResource
import SwiftUI

struct NetworksView: View {
    @Environment(NetworksModel.self) private var model
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
            if let error = model.lastError {
                ErrorBanner(error: error, onDismiss: { model.clearError() })
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
    /// The four subnet octets and the CIDR prefix length. All blank → let the
    /// plugin auto-allocate; otherwise composed into `a.b.c.d/mask`.
    @State private var octets: [String] = ["", "", "", ""]
    @State private var mask = "24"
    let onCreate: (String, Bool, String) -> Void

    /// Every octet filled — a subnet was actually entered.
    private var subnetProvided: Bool {
        octets.allSatisfy { !$0.isEmpty }
    }

    /// Valid when fully blank (auto-allocate) or fully filled with octets in
    /// 0–254 and a prefix length in 1–32.
    private var subnetValid: Bool {
        if octets.allSatisfy(\.isEmpty) { return true }
        guard subnetProvided else { return false }
        for octet in octets {
            guard let value = Int(octet), (0...254).contains(value) else { return false }
        }
        guard let prefix = Int(mask), (1...32).contains(prefix) else { return false }
        return true
    }

    private var subnetString: String {
        subnetProvided ? "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])/\(mask)" : ""
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && subnetValid
    }

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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        numberField($octets[0], placeholder: "192", max: 254, width: 52)
                        dot
                        numberField($octets[1], placeholder: "168", max: 254, width: 52)
                        dot
                        numberField($octets[2], placeholder: "100", max: 254, width: 52)
                        dot
                        numberField($octets[3], placeholder: "0", max: 254, width: 52)
                        HStack(spacing: 3) {
                            Text("/")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary.opacity(0.7))
                            numberField($mask, placeholder: "24", max: 32, width: 46)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Leave blank to auto-assign")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledSection(label: "Mode") {
                Toggle("Host-only (internal)", isOn: $hostOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

    private var dot: some View {
        Text(".").foregroundStyle(.secondary)
    }

    /// A digits-only field that clamps its value to `max` — used for both the
    /// subnet octets (0–254) and the prefix length (1–32).
    private func numberField(_ binding: Binding<String>, placeholder: String, max: Int, width: CGFloat) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.center)
            .onChange(of: binding.wrappedValue) { _, new in
                var digits = String(new.filter(\.isNumber).prefix(3))
                if let value = Int(digits), value > max { digits = String(max) }
                if digits != new { binding.wrappedValue = digits }
            }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, subnetValid else { return }
        onCreate(value, hostOnly, subnetString)
        dismiss()
    }
}
