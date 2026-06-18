//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import SwiftUI

/// Single-page sectioned form to create a container. Selecting an image analyzes
/// it and pre-fills ports, environment variables and volumes. The container runs
/// detached using the image's default command — the GUI has no terminal to drive
/// an overridden process, so command/entrypoint editing is intentionally absent.
struct CreateContainerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form = CreateContainerFormState()

    /// Volumes and networks offered in the mount / network pickers.
    let volumes: [VolumeConfiguration]
    let networks: [NetworkResource]
    /// Provides image analysis and performs the creation.
    let analyze: (String) async -> ImageMetadata
    let onCreate: (ContainerCreateSpec) -> Void

    private var canCreate: Bool {
        !form.image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        FormSheet(
            icon: "shippingbox",
            iconColor: Palette.containers,
            title: "Create Container",
            subtitle: "Runs detached with the image's default command.",
            width: .wide,
            height: 640
        ) {
            imageSection
            basicSection
            portsSection
            envSection
            mountsSection
            networkSection
            commandSection
            advancedSection
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                onCreate(form.makeSpec())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
        }
    }

    // MARK: Sections

    private var imageSection: some View {
        LabeledSection(label: "Image") {
            HStack(spacing: 8) {
                TextField("nginx:latest", text: $form.image)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runAnalysis)
                Button("Load") { runAnalysis() }
                    .disabled(form.image.trimmingCharacters(in: .whitespaces).isEmpty)
                if form.analyzing {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var basicSection: some View {
        LabeledSection(label: "Name") {
            TextField("Optional — auto-generated if blank", text: $form.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var portsSection: some View {
        LabeledSection(label: "Ports") {
            addButton("Add Port") { form.ports.append(PortRow()) }
        } content: {
            ForEach($form.ports) { $row in
                HStack(spacing: 6) {
                    TextField("host", text: $row.hostPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    TextField("container", text: $row.containerPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("/ \(row.proto)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    removeButton {
                        if let idx = form.ports.firstIndex(where: { $0.id == row.id }) {
                            form.ports.remove(at: idx)
                        }
                    }
                }
            }
        }
    }

    private var envSection: some View {
        LabeledSection(label: "Environment") {
            addButton("Add Variable") { form.envs.append(EnvRow()) }
        } content: {
            ForEach($form.envs) { $row in
                HStack(spacing: 6) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Text("=").foregroundStyle(.tertiary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                    removeButton {
                        if let idx = form.envs.firstIndex(where: { $0.id == row.id }) {
                            form.envs.remove(at: idx)
                        }
                    }
                }
            }
        }
    }

    private var mountsSection: some View {
        LabeledSection(label: "Volumes") {
            addButton("Add Mount") { form.mounts.append(MountRow(kind: defaultMountKind)) }
        } content: {
            ForEach($form.mounts) { $row in
                mountRow($row)
            }
        }
    }

    @ViewBuilder
    private func mountRow(_ row: Binding<MountRow>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: row.kind) {
                ForEach(MountRow.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            switch row.wrappedValue.kind {
            case .volume:
                Picker("", selection: row.source) {
                    Text("Select…").tag("")
                    ForEach(volumes) { volume in
                        Text(volume.name).tag(volume.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(volumes.isEmpty)
            case .bind:
                TextField("host path", text: row.source)
                    .textFieldStyle(.roundedBorder)
                Button {
                    chooseDirectory(into: row.source)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Choose a folder")
            }

            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            TextField("container path", text: row.containerPath)
                .textFieldStyle(.roundedBorder)
            Toggle("ro", isOn: row.readOnly)
                .toggleStyle(.checkbox)
                .help("Mount read-only")
            removeButton {
                if let idx = form.mounts.firstIndex(where: { $0.id == row.wrappedValue.id }) {
                    form.mounts.remove(at: idx)
                }
            }
        }
    }

    private var networkSection: some View {
        LabeledSection(label: "Network") {
            addButton("Add Network") { form.networks.append(NetworkRow()) }
        } content: {
            ForEach(Array($form.networks.enumerated()), id: \.element.id) { index, $row in
                HStack(spacing: 6) {
                    Picker("", selection: $row.selection) {
                        Text("Default").tag(NetworkSelection.default)
                        Text("None (no networking)").tag(NetworkSelection.none)
                        ForEach(namedNetworks, id: \.self) { name in
                            Text(name).tag(NetworkSelection.named(name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)
                    Spacer()
                    if index > 0 {
                        removeButton {
                            if let idx = form.networks.firstIndex(where: { $0.id == row.id }) {
                                form.networks.remove(at: idx)
                            }
                        }
                    }
                }
            }
        }
    }

    private var commandSection: some View {
        LabeledSection(label: "Command") {
            TextField("Image default — e.g. sleep infinity for shell images", text: $form.command)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var advancedSection: some View {
        LabeledSection(label: "Options") {
            HStack(spacing: 20) {
                Toggle("Remove when stopped", isOn: $form.autoRemove)
                    .fixedSize()
                Toggle("Forward SSH agent", isOn: $form.ssh)
                    .fixedSize()
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Helpers

    /// Networks the user can pick beyond the built-in Default / None entries.
    /// The built-in default network is represented by the "Default" option, so
    /// it is filtered out here to avoid a duplicate.
    private var namedNetworks: [String] {
        networks.filter { !$0.isBuiltin }.map(\.name).sorted()
    }

    /// Prefer Bind when no named volumes exist, so the picker isn't dead on arrival.
    private var defaultMountKind: MountRow.Kind {
        volumes.isEmpty ? .bind : .volume
    }

    private func chooseDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path(percentEncoded: false)
        }
    }

    private func runAnalysis() {
        let image = form.image
        form.analyzing = true
        Task {
            let metadata = await analyze(image)
            form.apply(metadata: metadata)
            form.analyzing = false
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
