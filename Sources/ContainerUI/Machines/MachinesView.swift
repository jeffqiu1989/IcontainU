import ContainerResource
import MachineAPIClient
import SwiftUI

struct MachinesView: View {
    @Environment(MachinesModel.self) private var model
    @State private var searchText = ""
    @State private var selectedID: MachineSnapshot.ID?
    @State private var pendingDelete: MachineSnapshot?
    @State private var showCreateSheet = false

    private var filteredMachines: [MachineSnapshot] {
        guard !searchText.isEmpty else { return model.machines }
        let query = searchText.lowercased()
        return model.machines.filter { $0.id.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let creating = model.creating {
                InlineProgressBar(progress: creating, accent: Palette.machines)
            }
            if let error = model.lastError {
                ErrorBanner(error: error, onDismiss: { model.clearError() })
            }
            cardGrid
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search machines")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Machine", systemImage: "plus")
                }
                .disabled(model.creating != nil)
            }
        }
        .task {
            await model.startPolling()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateMachineSheet { spec in
                Task {
                    await model.create(
                        image: spec.image,
                        name: spec.name,
                        cpus: spec.cpus,
                        memory: spec.memory,
                        homeMount: spec.homeMount,
                        setAsDefault: spec.setAsDefault,
                        noBoot: spec.noBoot)
                }
            }
        }
        .confirmationDialog(
            "Delete machine?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { machine in
            Button("Delete", role: .destructive) {
                Task { await model.delete(machine) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text("\(machine.id) and its persistent storage will be permanently removed.")
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.machines.isEmpty {
            ContentUnavailableView("No Machines", systemImage: "server.rack")
        } else if filteredMachines.isEmpty {
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
                    ForEach(filteredMachines) { machine in
                        MachineCard(
                            machine: machine,
                            isDefault: machine.id == model.defaultID,
                            isSelected: selectedID == machine.id,
                            onSelect: {
                                selectedID = (selectedID == machine.id) ? nil : machine.id
                            },
                            onBoot: { Task { await model.boot(machine) } },
                            onStop: { Task { await model.stop(machine) } },
                            onRun: { model.openShell(machine) },
                            onDelete: { pendingDelete = machine }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Form inputs for creating a machine.
struct CreateMachineSpec {
    var image: String
    var name: String?
    var cpus: Int?
    var memory: String?
    var homeMount: String?
    var setAsDefault: Bool
    var noBoot: Bool
}

/// Pre-configured machine images that include /sbin/init and are known to work.
/// The last entry (.custom) lets the user type any reference, with a warning.
enum MachineImagePreset: String, CaseIterable, Identifiable {
    case alpine = "Alpine (latest)"
    case rocky9 = "Rocky Linux 9"
    case rocky8 = "Rocky Linux 8"
    case rocky10 = "Rocky Linux 10"
    case custom = "Custom…"

    var id: String { rawValue }

    /// The full image reference for the preset, or nil for custom.
    var reference: String? {
        switch self {
        case .alpine: "alpine:latest"
        case .rocky9: "rockylinux/rockylinux:9-ubi-init"
        case .rocky8: "rockylinux/rockylinux:8-ubi-init"
        case .rocky10: "rockylinux/rockylinux:10-ubi-init"
        case .custom: nil
        }
    }
}

/// Modal to create a machine. Required fields first, optional tuning grouped
/// below; blank optional fields fall back to system defaults.
private struct CreateMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: MachineImagePreset = .alpine
    @State private var customImage = ""
    @State private var showInitWarning = false
    @State private var name = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var homeMount = "rw"
    @State private var setAsDefault = false
    @State private var noBoot = false

    let onCreate: (CreateMachineSpec) -> Void

    private var resolvedImage: String {
        selectedPreset.reference ?? customImage.trimmingCharacters(in: .whitespaces)
    }

    private var canCreate: Bool {
        !resolvedImage.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    requiredSection
                    resourcesSection
                    optionsSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 560)
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Machine")
                    .font(.title3.weight(.semibold))
                Text("Spin up a persistent Linux VM from an image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
        .padding(16)
    }

    // MARK: Sections

    private var requiredSection: some View {
        section(title: "Machine", subtitle: "Image must contain an init system (e.g. systemd)") {
            labeledField("Distribution") {
                Picker("", selection: $selectedPreset) {
                    ForEach(MachineImagePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            labeledField("Image") {
                if selectedPreset == .custom {
                    TextField("e.g. myorg/myimage:latest", text: $customImage)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(selectedPreset.reference ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            labeledField("Name") {
                TextField("Optional — auto-generated if blank", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onChange(of: selectedPreset) { _, newValue in
            if newValue == .custom { showInitWarning = true }
        }
        .alert("Image Requirements", isPresented: $showInitWarning) {
            Button("I Understand") {}
        } message: {
            Text(
                "The image must include /sbin/init (systemd, SysVinit, busybox init, etc.). "
                    + "Standard ubuntu/debian/fedora container images do NOT have init and will fail to boot. "
                    + "Use alpine, Rocky Linux UBI-init variants, or build a custom image with systemd.")
        }
    }

    private var resourcesSection: some View {
        section(title: "Resources", subtitle: "Optional — blank uses system defaults") {
            labeledField("CPUs") {
                TextField("e.g. 4", text: $cpus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            labeledField("Memory") {
                TextField("e.g. 4G", text: $memory)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            labeledField("Home mount") {
                Picker("", selection: $homeMount) {
                    Text("Read-write").tag("rw")
                    Text("Read-only").tag("ro")
                    Text("None").tag("none")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private var optionsSection: some View {
        section(title: "Options", subtitle: nil) {
            Toggle(isOn: $setAsDefault) {
                Text("Set as default machine")
                Text("Use this machine when no name is given.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $noBoot) {
                Text("Create without booting")
                Text("The machine is created but left stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section(title: String, subtitle: String?, @ViewBuilder content: () -> some View)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func labeledField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            field()
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard !resolvedImage.isEmpty else { return }
        let spec = CreateMachineSpec(
            image: resolvedImage,
            name: name.isEmpty ? nil : name,
            cpus: Int(cpus.trimmingCharacters(in: .whitespaces)),
            memory: memory.isEmpty ? nil : memory,
            homeMount: homeMount,
            setAsDefault: setAsDefault,
            noBoot: noBoot)
        onCreate(spec)
        dismiss()
    }
}
