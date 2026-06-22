import SwiftUI

/// Manages registry mirror mappings used to accelerate image pulls. Mappings are
/// GUI-only: they rewrite references before pull, affecting only pulls issued
/// from this app.
struct RegistriesView: View {
    @State private var store = RegistryMirrorStore.shared
    @State private var showAddSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if store.mirrors.isEmpty {
                    ContentUnavailableView {
                        Label("No Mirrors", systemImage: "arrow.triangle.swap")
                    } description: {
                        Text("Add a mirror mapping or import a preset to accelerate pulls.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach(store.mirrors) { mirror in
                        MirrorRow(
                            mirror: mirror,
                            onToggle: { store.setEnabled(mirror, $0) },
                            onDelete: { store.remove(mirror) }
                        )
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showAddSheet) {
            AddMirrorSheet { source, mirror in
                store.add(source: source, mirror: mirror)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registry Mirrors")
                .font(.title2.weight(.semibold))
            Text("Rewrites image references when pulling from this app, so slow or blocked registries can be served from a mirror. Does not affect the CLI.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Mirror", systemImage: "plus")
                }
                Button {
                    store.importDaoCloudPreset()
                } label: {
                    Label("Import DaoCloud Preset", systemImage: "square.and.arrow.down")
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One mirror mapping row.
private struct MirrorRow: View {
    let mirror: RegistryMirror
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(get: { mirror.enabled }, set: { onToggle($0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mirror.source)
                        .font(.callout.weight(.medium))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(mirror.mirror)
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(12)
        .opacity(mirror.enabled ? 1 : 0.5)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.22), lineWidth: 1)
        }
    }
}

/// Modal to add a mirror mapping.
private struct AddMirrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var mirror = ""
    let onAdd: (String, String) -> Void

    var body: some View {
        FormSheet(
            icon: "key",
            iconColor: Palette.registries,
            title: "Add Mirror"
        ) {
            LabeledSection(label: "Source") {
                TextField("e.g. docker.io", text: $source)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledSection(label: "Mirror") {
                TextField("e.g. docker.m.daocloud.io", text: $mirror)
                    .textFieldStyle(.roundedBorder)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    source.trimmingCharacters(in: .whitespaces).isEmpty
                        || mirror.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        onAdd(source, mirror)
        dismiss()
    }
}
