import ContainerResource
import SwiftUI
import UniformTypeIdentifiers

/// Import a compose file: choose a file (or paste YAML), Analyze to parse
/// services into editable cards, then Up. Each service's image, ports, env,
/// volumes, networks, command, user, and container name are configurable before
/// bringing the project up.
struct ImportComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ComposeModel

    @State private var yamlText = ""
    @State private var baseDirectory: URL?
    @State private var projectName = ""
    @State private var formState = ComposeImportFormState()
    @State private var originalFile: ComposeFile?
    @State private var analyzeError: String?

    /// Volumes referenced across all services (for the volume picker). The form
    /// stores each mount's source as the raw, unprefixed YAML volume name (e.g.
    /// `data`), so the picker options must be unprefixed too — otherwise the parsed
    /// selection never matches an option and the picker falls back to "Choose…".
    /// The project prefix is reapplied later in `makeSpec`.
    private var composeVolumes: [VolumeConfiguration] {
        formState.declaredVolumes.map { full in
            let unprefixed = full.hasPrefix(formState.projectName + "_")
                ? String(full.dropFirst(formState.projectName.count + 1))
                : full
            return VolumeConfiguration(name: unprefixed, source: "compose_\(unprefixed)")
        }
    }

    /// Network options shared by all services.
    private var composeNetworkOptions: [(value: NetworkSelection, title: String)] {
        var options: [(value: NetworkSelection, title: String)] = [
            (.default, "default"),
            (.none, "none"),
        ]
        for net in formState.declaredNetworks {
            let unprefixed = net.hasPrefix(formState.projectName + "_")
                ? String(net.dropFirst(formState.projectName.count + 1))
                : net
            options.append((.named(unprefixed), unprefixed))
        }
        return options
    }

    private var canAnalyze: Bool {
        !yamlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !projectName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canUp: Bool {
        !formState.serviceConfigs.isEmpty && canAnalyze
    }

    var body: some View {
        FormSheet(
            icon: "square.stack.3d.up",
            iconColor: Palette.compose,
            title: "New Compose Project",
            subtitle: "Import a compose file, configure each service, then bring them up together.",
            width: .wide,
            height: 720
        ) {
            sourceSection
            nameSection
            if let analyzeError {
                errorBox(analyzeError)
            }
            if !formState.serviceConfigs.isEmpty {
                warningsBanner
                servicesEditor
                sharedResourcesView
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
                .onChange(of: projectName) { _, _ in
                    formState = ComposeImportFormState()
                    originalFile = nil
                }
            if model.projectExists(projectName.trimmingCharacters(in: .whitespaces)) {
                Text("A project with this name already exists — Up will update it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Services editor

    /// Project-wide parse warnings (ignored fields, dropped long-syntax entries,
    /// service_healthy deps without a healthcheck, auto-created networks). Computed
    /// during Analyze and shown here so the user sees them before bringing the
    /// project up.
    @ViewBuilder
    private var warningsBanner: some View {
        if !formState.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(formState.warnings.count) warning\(formState.warnings.count == 1 ? "" : "s")")
                        .font(.callout.weight(.semibold))
                }
                ForEach(formState.warnings, id: \.self) { warning in
                    Text("• " + warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var servicesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Services")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
            ForEach(formState.serviceConfigs) { config in
                ServiceEditorCard(
                    config: config,
                    composeVolumes: composeVolumes,
                    composeNetworkOptions: composeNetworkOptions
                )
            }
        }
    }

    private var sharedResourcesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !formState.declaredNetworks.isEmpty {
                resourceLine("Networks", formState.declaredNetworks)
            }
            if !formState.declaredVolumes.isEmpty {
                resourceLine("Volumes", formState.declaredVolumes)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.compose.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func resourceLine(_ label: String, _ values: [String]) -> some View {
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
        formState = ComposeImportFormState()
        originalFile = nil
        analyzeError = nil
        analyze()
    }

    private func analyze() {
        analyzeError = nil
        formState = ComposeImportFormState()
        originalFile = nil
        let name = projectName.trimmingCharacters(in: .whitespaces)
        do {
            let (file, result) = try model.analyzeWithFile(
                yaml: yamlText, baseDirectory: baseDirectory, projectName: name)
            originalFile = file
            formState.projectName = name
            formState.yamlText = yamlText
            formState.baseDirectory = baseDirectory
            formState.load(from: file, parseResult: result)
        } catch {
            analyzeError = error.localizedDescription
        }
    }

    private func up() {
        let name = projectName.trimmingCharacters(in: .whitespaces)
        do {
            let parse = try formState.makeParseResult(baseDirectory: baseDirectory)
            let overrides = originalFile.map { formState.buildServiceOverrides(from: $0) } ?? [:]
            let record = ComposeProjectRecord(
                name: name,
                yaml: yamlText,
                baseDirectoryPath: baseDirectory?.path,
                declaredNetworks: formState.declaredNetworks,
                declaredVolumes: formState.declaredVolumes,
                importedAt: Date(),
                serviceOverrides: overrides.isEmpty ? nil : overrides)
            model.startUp(record: record, parse: parse)
            dismiss()
        } catch {
            analyzeError = error.localizedDescription
        }
    }
}

// MARK: - Service Editor Card

/// An editable card for one compose service. Collapsible; header shows the
/// service name, image, and expand/collapse chevron. Expanded body has one
/// consistent leading-label column for image, container name, ports, env,
/// volumes, networks, command, user, plus read-only depends_on / healthcheck
/// summaries. Sections with no parsed values are hidden. Rows can't be added or
/// removed — editing existing values only.
private struct ServiceEditorCard: View {
    @Bindable var config: ComposeServiceConfig
    let composeVolumes: [VolumeConfiguration]
    let composeNetworkOptions: [(value: NetworkSelection, title: String)]

    /// The mount row whose volume suggestion list is open — drives zIndex so the
    /// floating list paints above the card rows (Networks, Command…) below it.
    @State private var activeMountIndex: Int?

    /// Shared label-column width so every row in the card lines up.
    private static let labelWidth: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if config.isExpanded {
                Divider().padding(.horizontal, 12)
                fields.padding(12)
            }
        }
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cardBorder, lineWidth: 1) }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                config.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(Palette.compose)
                Text(config.serviceName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(config.image)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if !config.dependsOn.isEmpty {
                    Text(config.dependsOn.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Image(systemName: config.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardRow("Image") {
                TextField("image", text: $config.image)
                    .textFieldStyle(.roundedBorder)
            }

            cardRow("Name") {
                HStack(spacing: 6) {
                    TextField("container name", text: $config.containerName)
                        .textFieldStyle(.roundedBorder)
                    if config.containerNameOverridden {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.secondary)
                            .help("Manually overridden")
                    }
                }
            }

            if !config.ports.isEmpty {
                cardRow("Ports") { portRows }
            }
            if !config.envs.isEmpty {
                cardRow("Environment") { envRows }
            }
            if !config.mounts.isEmpty {
                cardRow("Volumes") { mountRows }
                    // Raise the Volumes row above the rows below it while a volume
                    // suggestion list is open, so it isn't painted over.
                    .zIndex(activeMountIndex != nil ? 1 : 0)
            }
            if !config.networks.isEmpty {
                cardRow("Networks") { networkRows }
            }

            cardRow("Command") {
                TextField("command", text: $config.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            cardRow("User") {
                TextField("user (optional)", text: $config.user)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120, alignment: .leading)
            }

            if !config.dependsOn.isEmpty {
                cardRow("Depends") { dependsRow }
            }

            if let hc = config.healthcheck {
                cardRow("Health") {
                    Text(healthSummary(hc))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// The depends_on summary: each dependency, with a small "healthy" tag for any
    /// dependency gated on `condition: service_healthy` (vs plain start order).
    private var dependsRow: some View {
        HStack(spacing: 6) {
            ForEach(config.dependsOn, id: \.self) { dep in
                HStack(spacing: 3) {
                    Text(dep)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if config.dependsOnConditions[dep] == "service_healthy" {
                        Text("healthy")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    // MARK: - Port rows

    private var portRows: some View {
        ForEach(Array(config.ports.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 6) {
                SegmentedToggle(selection: $config.ports[index].proto, segments: [
                    .init("tcp", text: "TCP"),
                    .init("udp", text: "UDP"),
                ])
                .frame(width: 76)
                TextField("host", text: $config.ports[index].hostPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text(":").foregroundStyle(.secondary)
                TextField("container", text: $config.ports[index].containerPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Env rows

    private var envRows: some View {
        ForEach(Array(config.envs.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 6) {
                TextField("KEY", text: $config.envs[index].key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("=").foregroundStyle(.secondary)
                TextField("value", text: $config.envs[index].value)
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Mount rows

    private var mountRows: some View {
        ForEach(Array(config.mounts.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 6) {
                // Volume name and bind path are stored independently, so switching
                // kind preserves whatever was entered for the other mode.
                SegmentedToggle(selection: $config.mounts[index].kind, segments: [
                    .init(.volume, systemImage: "externaldrive"),
                    .init(.bind, systemImage: "folder"),
                ])
                .frame(width: 76)
                switch config.mounts[index].kind {
                case .volume:
                    AutocompleteField(
                        text: $config.mounts[index].volumeName,
                        options: composeVolumes.map(\.name),
                        placeholder: "volume_name",
                        icon: "externaldrive",
                        iconColor: Palette.volumes,
                        onActiveChange: { active in
                            activeMountIndex = active ? index : (activeMountIndex == index ? nil : activeMountIndex)
                        })
                    .frame(maxWidth: 200, alignment: .leading)
                case .bind:
                    TextField("~/path", text: $config.mounts[index].bindPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let dir = chooseDirectory() {
                            config.mounts[index].bindPath = dir.path
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a folder")
                }
                Text(":").foregroundStyle(.secondary)
                TextField("/path", text: $config.mounts[index].containerPath)
                    .textFieldStyle(.roundedBorder)
                Toggle("ro", isOn: $config.mounts[index].readOnly)
                    .toggleStyle(.checkbox)
                    .help("Mount read-only")
                Spacer(minLength: 0)
            }
            .zIndex(index == activeMountIndex ? 1 : 0)
        }
    }

    // MARK: - Network rows

    private var networkRows: some View {
        ForEach(Array(config.networks.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 6) {
                StyledPicker(
                    selection: $config.networks[index].selection,
                    options: composeNetworkOptions,
                    minWidth: 160)
                .frame(maxWidth: 220, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    /// One labeled row: a fixed leading label column, content trailing. Used for
    /// every field so the card aligns on a single label edge.
    private func cardRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func healthSummary(_ hc: ComposeHealthcheck) -> String {
        let probe: String
        switch hc.probe {
        case .cmd(let argv): probe = argv.joined(separator: " ")
        case .cmdShell(let script): probe = script
        case .none: return "disabled"
        }
        let interval = hc.interval == hc.interval.rounded()
            ? "\(Int(hc.interval))s" : "\(hc.interval)s"
        return "\(probe)  ·  every \(interval), \(hc.retries)×"
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
