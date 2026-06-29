import SwiftUI
import UniformTypeIdentifiers

/// Import a compose file: choose a file (or paste YAML), Analyze to preview the
/// services and shared resources, then Up. Mirrors `CreateContainerSheet`'s
/// analyze-then-act flow. Editing is intentionally read-only — the YAML is the
/// single source of truth; to change something, edit the file and Analyze again.
struct ImportComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ComposeModel

    @State private var yamlText = ""
    @State private var baseDirectory: URL?
    @State private var projectName = ""
    @State private var parseResult: ComposeParseResult?
    @State private var analyzeError: String?

    private var canAnalyze: Bool {
        !yamlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !projectName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canUp: Bool { parseResult != nil && canAnalyze }

    var body: some View {
        FormSheet(
            icon: "square.stack.3d.up",
            iconColor: Palette.compose,
            title: "New Compose Project",
            subtitle: "Import a compose file and bring its services up together.",
            width: .wide,
            height: 640
        ) {
            sourceSection
            nameSection
            if let analyzeError {
                errorBox(analyzeError)
            }
            if let result = parseResult {
                warningsView(result)
                previewView(result)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Analyze") { analyze() }
                .buttonStyle(.blueOutline)
                .disabled(!canAnalyze)
            Button("Up") { up() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.compose)
                .disabled(!canUp)
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        LabeledSection(label: "File") {
            HStack(spacing: 8) {
                Button {
                    chooseFile()
                } label: {
                    Label("Choose compose file…", systemImage: "folder")
                }
                .buttonStyle(.blueOutline)
                if let baseDirectory {
                    Text(baseDirectory.lastPathComponent + "/")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }

    private var nameSection: some View {
        LabeledSection(label: "Project") {
            TextField("project name", text: $projectName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onChange(of: projectName) { _, _ in parseResult = nil }
            if model.projectExists(projectName.trimmingCharacters(in: .whitespaces)) {
                Text("A project with this name already exists — Up will update it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func warningsView(_ result: ComposeParseResult) -> some View {
        if !result.warnings.isEmpty {
            LabeledSection(label: "Notes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func previewView(_ result: ComposeParseResult) -> some View {
        LabeledSection(label: "Services") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.orderedServices, id: \.self) { service in
                    if let spec = result.specs[service] {
                        servicePreview(service: service, spec: spec)
                    }
                }
                if !result.declaredNetworks.isEmpty || !result.declaredVolumes.isEmpty {
                    sharedResources(result)
                }
            }
        }
    }

    private func servicePreview(service: String, spec: ContainerCreateSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.caption).foregroundStyle(Palette.compose)
                Text(service).font(.callout.weight(.semibold))
                Text(spec.image).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            metaLine("Ports", spec.publishPorts)
            metaLine("Env", spec.env.map { String($0.split(separator: "=").first ?? "") })
            metaLine("Volumes", spec.volumes)
            metaLine("Networks", spec.networks)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cardBorder, lineWidth: 1) }
    }

    @ViewBuilder
    private func metaLine(_ label: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .leading)
                Text(values.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func sharedResources(_ result: ComposeParseResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !result.declaredNetworks.isEmpty {
                metaLine("Networks", result.declaredNetworks)
            }
            if !result.declaredVolumes.isEmpty {
                metaLine("Volumes", result.declaredVolumes)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.compose.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.yaml, UTType.plainText].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            analyzeError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        yamlText = text
        baseDirectory = url.deletingLastPathComponent()
        // Default the project name to the file's directory (docker compose's default).
        if projectName.trimmingCharacters(in: .whitespaces).isEmpty {
            projectName = url.deletingLastPathComponent().lastPathComponent
        }
        parseResult = nil
        analyzeError = nil
        analyze()
    }

    private func analyze() {
        analyzeError = nil
        parseResult = nil
        let name = projectName.trimmingCharacters(in: .whitespaces)
        do {
            parseResult = try model.analyze(yaml: yamlText, baseDirectory: baseDirectory, projectName: name)
        } catch {
            analyzeError = error.localizedDescription
        }
    }

    private func up() {
        let name = projectName.trimmingCharacters(in: .whitespaces)
        let record = ComposeProjectRecord(
            name: name,
            yaml: yamlText,
            baseDirectoryPath: baseDirectory?.path,
            declaredNetworks: parseResult?.declaredNetworks ?? [],
            declaredVolumes: parseResult?.declaredVolumes ?? [],
            importedAt: Date())
        model.startUp(record: record)
        dismiss()
    }
}
