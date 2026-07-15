import ContainerResource
import SwiftUI

/// Single-page sectioned form to create a container. Selecting an image analyzes
/// it and pre-fills ports, environment variables and volumes. The container runs
/// detached using the image's default command — the GUI has no terminal to drive
/// an overridden process, so command/entrypoint editing is intentionally absent.
struct CreateContainerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form = CreateContainerFormState()
    @FocusState private var imageFieldFocused: Bool
    /// Keyboard-highlighted row in the image suggestion list (arrow-key navigation).
    @State private var highlightedSuggestion = 0
    /// Measured height of the image text field, so the suggestion list floats just
    /// below it without a magic offset.
    @State private var imageFieldHeight: CGFloat = FieldHeightKey.defaultValue
    /// The mount row whose volume suggestion list is currently open, raised in
    /// zIndex so its floating list paints above the rows and sections below.
    @State private var activeMountRowID: MountRow.ID?
    /// Pull / analyze error surfaced as an alert inside this sheet so it's not
    /// hidden behind the modal (the model's banner lives in ContainersView).
    @State private var pullError: OperationError?
    @State private var bindPathError: String?

    /// Backs image autocomplete, local/remote detection, pull and analysis.
    let model: ContainersModel
    /// Volumes and networks offered in the mount / network pickers.
    let volumes: [VolumeConfiguration]
    let networks: [NetworkResource]
    let onCreate: (ContainerCreateSpec) -> Void

    private var canCreate: Bool {
        !form.image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Names already taken, so an auto-generated name never collides.
    private var existingNames: Set<String> {
        Set(model.containers.map(\.id))
    }

    /// Whether the typed image is already present locally (Analyze) or must be
    /// fetched first (Pull). Recomputed as the user types so the button stays live.
    private var imageIsLocal: Bool {
        model.isImageLocal(form.image)
    }

    /// Max suggestion rows shown at once; extra matches collapse into a "More" row.
    private static let maxSuggestions = 5

    /// Local images matching the current input by prefix. An empty input (just
    /// focused) lists everything, so suggestions appear the moment the field is
    /// clicked into.
    private var allImageMatches: [String] {
        let query = form.image.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.availableImages }
        return model.availableImages.filter { $0.lowercased().hasPrefix(query) }
    }

    /// The (capped) rows actually rendered in the suggestion list.
    private var imageSuggestions: [String] {
        Array(allImageMatches.prefix(Self.maxSuggestions))
    }

    private var hasMoreSuggestions: Bool {
        allImageMatches.count > imageSuggestions.count
    }

    private var suggestionsVisible: Bool {
        imageFieldFocused && !imageSuggestions.isEmpty
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
                .zIndex(1)  // keep the floating suggestion list above later rows
            nameSection
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
                // Ensure bind-mount host directories exist before creating.
                // On failure, show an alert so the user can fix the path and retry.
                let fm = FileManager.default
                for row in form.mounts where row.kind == .bind {
                    let path = row.bindPath.trimmingCharacters(in: .whitespaces)
                    guard !path.isEmpty else { continue }
                    let resolved = path.hasPrefix("~")
                        ? (path as NSString).expandingTildeInPath
                        : path
                    // Skip if the source already exists — a file bind-mount is
                    // ready as-is and must not be turned into a directory; an
                    // existing directory is a no-op too.
                    if fm.fileExists(atPath: resolved) { continue }
                    do {
                        try fm.createDirectory(atPath: resolved, withIntermediateDirectories: true)
                    } catch {
                        bindPathError = "Cannot create bind-mount directory \"\(resolved)\": \(error.localizedDescription)"
                        return
                    }
                }
                onCreate(form.makeSpec(builtinNetworkName: networks.first { $0.isBuiltin }?.name))
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
        }
        .alert(
            pullError?.title ?? "",
            isPresented: Binding(get: { pullError != nil }, set: { if !$0 { pullError = nil } }),
            presenting: pullError
        ) { error in
            Button("OK") {}
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(error.title)\n\(error.detail)", forType: .string)
            }
        } message: { error in
            Text(error.detail)
        }
        .alert(
            "Bind Mount Error",
            isPresented: Binding(
                get: { bindPathError != nil },
                set: { if !$0 { bindPathError = nil } }),
            presenting: bindPathError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Sections

    private var imageSection: some View {
        LabeledSection(label: "Image") {
            HStack(alignment: .top, spacing: 8) {
                // The field and its progress bar share a column so both line up
                // under the input. The suggestion list is a floating overlay (see
                // below) so it doesn't push the rest of the form down.
                VStack(alignment: .leading, spacing: 6) {
                    TextField("nginx:latest", text: $form.image)
                        .textFieldStyle(.roundedBorder)
                        .focused($imageFieldFocused)
                        .onKeyPress(.downArrow) { moveHighlight(1) }
                        .onKeyPress(.upArrow) { moveHighlight(-1) }
                        .onKeyPress(.return) { commitHighlightOrLoad() }
                        .onKeyPress(.escape) {
                            imageFieldFocused = false
                            return .handled
                        }
                        .onChange(of: form.image) { _, _ in highlightedSuggestion = 0 }
                        .onChange(of: imageFieldFocused) { _, _ in highlightedSuggestion = 0 }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: FieldHeightKey.self, value: geo.size.height)
                            }
                        )
                        .onPreferenceChange(FieldHeightKey.self) { imageFieldHeight = $0 }
                        // Float the suggestion list just below the field (offset by
                        // its measured height) so it overlays following rows instead
                        // of displacing them and never covers the field. The section's
                        // raised zIndex (in `body`) keeps it above later rows.
                        .overlay(alignment: .topLeading) {
                            if suggestionsVisible {
                                suggestionList.offset(y: imageFieldHeight + 4)
                            }
                        }
                    if let progress = model.pulling {
                        InlineProgressBar(progress: progress, accent: Palette.containers,
                                          onCancel: { model.cancelPull() })
                    }
                }
                loadButton
                if form.analyzing {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var nameSection: some View {
        LabeledSection(label: "Name") {
            HStack(spacing: 8) {
                TextField("container name", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                // Invisible placeholder matching loadButton's width so the
                // Name TextField aligns with Image's TextField.
                loadButton.hidden()
            }
        }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard suggestionsVisible else { return .ignored }
        let count = imageSuggestions.count
        highlightedSuggestion = max(0, min(count - 1, highlightedSuggestion + delta))
        return .handled
    }

    private func commitHighlightOrLoad() -> KeyPress.Result {
        if suggestionsVisible, imageSuggestions.indices.contains(highlightedSuggestion) {
            selectSuggestion(imageSuggestions[highlightedSuggestion])
            return .handled
        }
        loadAction()
        return .handled
    }

    private func selectSuggestion(_ reference: String) {
        form.image = reference
        imageFieldFocused = false
    }

    /// Analyze when the image is already local, Pull when it must be fetched first.
    @ViewBuilder
    private var loadButton: some View {
        let busy = form.analyzing || model.pulling != nil
        let disabled = form.image.trimmingCharacters(in: .whitespaces).isEmpty || busy
        Button(imageIsLocal ? "Analyze" : "Pull") { loadAction() }
            .buttonStyle(.blueOutline)
            .disabled(disabled)
            .help(imageIsLocal ? "Analyze the local image and pre-fill the form" : "Not found locally — pull, then analyze")
    }

    /// The local-image suggestion dropdown shown beneath the image field, aligned
    /// to the field's width. The keyboard-highlighted row is tinted.
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(imageSuggestions.enumerated()), id: \.element) { index, reference in
                Button {
                    selectSuggestion(reference)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "opticaldiscdrive")
                            .font(.caption)
                            .foregroundStyle(Palette.images)
                        Text(reference)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlightedSuggestion ? Palette.networks.opacity(0.14) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index != imageSuggestions.count - 1 || hasMoreSuggestions {
                    Divider().opacity(0.4)
                }
            }
            if hasMoreSuggestions {
                Text("More…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Palette.networks.opacity(0.5), lineWidth: 1)
        }
    }

    private var portsSection: some View {
        LabeledSection(label: "Ports") {
            ForEach($form.ports) { $row in
                HStack(spacing: 6) {
                    SegmentedToggle(selection: $row.proto, segments: [
                        .init("tcp", text: "TCP"),
                        .init("udp", text: "UDP"),
                    ])
                    .frame(width: 76)
                    TextField("host port", text: $row.hostPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                    Text(":").foregroundStyle(.secondary)
                    TextField("port", text: $row.containerPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                    Spacer(minLength: 8)
                    rowControl(isFirst: row.id == form.ports.first?.id) {
                        form.ports.append(PortRow())
                    } onRemove: {
                        removePort(row)
                    }
                }
            }
        }
    }

    private func removePort(_ row: PortRow) {
        form.ports.removeAll { $0.id == row.id }
        if form.ports.isEmpty { form.ports = [PortRow()] }
    }

    private var envSection: some View {
        LabeledSection(label: "Environment") {
            ForEach($form.envs) { $row in
                HStack(spacing: 6) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Text("=").foregroundStyle(.tertiary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Spacer(minLength: 8)
                    rowControl(isFirst: row.id == form.envs.first?.id) {
                        form.envs.append(EnvRow())
                    } onRemove: {
                        removeEnv(row)
                    }
                }
            }
        }
    }

    private func removeEnv(_ row: EnvRow) {
        form.envs.removeAll { $0.id == row.id }
        if form.envs.isEmpty { form.envs = [EnvRow()] }
    }

    private var mountsSection: some View {
        LabeledSection(label: "Volumes") {
            ForEach($form.mounts) { $row in
                mountRow($row, isFirst: $row.wrappedValue.id == form.mounts.first?.id)
                    // Raise the row whose volume list is open so it floats above the
                    // rows below it.
                    .zIndex(row.id == activeMountRowID ? 1 : 0)
            }
        }
        // Raise the whole section above later sections (Network, Command…) while a
        // volume suggestion list is open, so it isn't painted over.
        .zIndex(activeMountRowID != nil ? 2 : 0)
    }

    @ViewBuilder
    private func mountRow(_ row: Binding<MountRow>, isFirst: Bool) -> some View {
        HStack(spacing: 6) {
            SegmentedToggle(selection: row.kind, segments: [
                .init(.volume, systemImage: "externaldrive"),
                .init(.bind, systemImage: "folder"),
            ])
            .frame(width: 76)

            switch row.wrappedValue.kind {
            case .volume:
                AutocompleteField(
                    text: row.volumeName,
                    options: volumes.map(\.name),
                    placeholder: "volume name",
                    icon: "externaldrive",
                    iconColor: Palette.volumes,
                    onActiveChange: { active in
                        setMountRowActive(row.wrappedValue.id, active)
                    })
                .frame(maxWidth: .infinity, alignment: .leading)
            case .bind:
                TextField("host path", text: row.bindPath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    chooseDirectory(into: row.bindPath)
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
            rowControl(isFirst: isFirst) {
                form.mounts.append(MountRow(kind: defaultMountKind))
            } onRemove: {
                removeMount(row.wrappedValue)
            }
        }
    }

    /// Track which mount row's volume suggestion list is open, to drive zIndex.
    private func setMountRowActive(_ id: MountRow.ID, _ active: Bool) {
        if active {
            activeMountRowID = id
        } else if activeMountRowID == id {
            activeMountRowID = nil
        }
    }

    private func removeMount(_ row: MountRow) {
        form.mounts.removeAll { $0.id == row.id }
        if form.mounts.isEmpty { form.mounts = [MountRow()] }
    }

    private var networkSection: some View {
        LabeledSection(label: "Network") {
            ForEach(Array($form.networks.enumerated()), id: \.element.id) { index, $row in
                HStack(spacing: 6) {
                    StyledPicker(
                        selection: $row.selection,
                        options: networkOptions,
                        minWidth: 220)
                    .frame(maxWidth: 300, alignment: .leading)
                    Spacer(minLength: 8)
                    rowControl(isFirst: index == 0) {
                        form.networks.append(NetworkRow())
                    } onRemove: {
                        removeNetwork(row.id)
                    }
                }
            }
        }
    }

    private func removeNetwork(_ id: NetworkRow.ID) {
        form.networks.removeAll { $0.id == id }
        if form.networks.isEmpty { form.networks = [NetworkRow()] }
    }

    private var commandSection: some View {
        LabeledSection(label: "Command") {
            TextField("commands", text: $form.command)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var advancedSection: some View {
        LabeledSection(label: "Options") {
            HStack(spacing: 20) {
                Toggle("Remove when stopped", isOn: $form.autoRemove)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                Toggle("Forward SSH agent", isOn: $form.ssh)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

    /// The network dropdown's entries: built-in Default / None, then named networks.
    private var networkOptions: [(value: NetworkSelection, title: String)] {
        var options: [(NetworkSelection, String)] = [
            (.default, "Default"),
            (.none, "None (no networking)"),
        ]
        options.append(contentsOf: namedNetworks.map { (.named($0), $0) })
        return options
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

    /// Load = Pull-then-Analyze for a remote image, or Analyze directly for a local
    /// one. After analysis, fill an empty Name field with a generated one (#2).
    /// Errors during pull / analyze are surfaced as an alert inside the sheet so
    /// they aren't hidden behind the modal.
    private func loadAction() {
        let image = form.image.trimmingCharacters(in: .whitespaces)
        guard !image.isEmpty, !form.analyzing, model.pulling == nil else { return }
        imageFieldFocused = false
        // Clear any stale model error before starting (the alert reads the model
        // error after each step).
        model.clearError()
        Task { @MainActor in
            if !model.isImageLocal(image) {
                model.startPullForCreate(reference: image)
                guard await model.pullForCreateTask?.value == true else {
                    pullError = model.lastError
                    model.clearError()
                    return
                }
            }
            form.analyzing = true
            let metadata = await model.analyze(image: image)
            form.apply(metadata: metadata)
            form.analyzing = false
            if let error = model.lastError {
                pullError = error
                model.clearError()
                return
            }
            if form.name.trimmingCharacters(in: .whitespaces).isEmpty {
                form.name = NameGenerator.random(avoiding: existingNames)
            }
            form.analyzing = false
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
    }

    /// Inline row control, unified across every dynamic section: the first row
    /// carries ⊕ to append a new row, every other row carries ⊖ to delete itself.
    /// The first row is never removable, which keeps each section non-empty.
    @ViewBuilder
    private func rowControl(
        isFirst: Bool, onAdd: @escaping () -> Void, onRemove: @escaping () -> Void
    ) -> some View {
        if isFirst {
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Palette.networks)
            }
            .buttonStyle(.borderless)
            .help("Add a row")
        } else {
            removeButton(onRemove)
        }
    }

}
