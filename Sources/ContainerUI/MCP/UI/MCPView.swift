import SwiftUI
import UniformTypeIdentifiers

/// Control panel for the embedded MCP server: enable/disable, bind config, API
/// keys, and a live request log. Styled to match the app's other settings-style
/// screens (RegistriesView) — sectioned cards on a neutral surface, no material.
struct MCPView: View {
    @Environment(MCPServerManager.self) private var server
    @State private var showNewKeySheet = false
    @State private var generatedKey: MCPSettings.APIKey?
    @State private var showGeneratedKey = false
    @State private var portText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                serverCard
                keysCard
                logCard
            }
            .padding(16)
        }
        .onAppear { portText = "\(server.settings.port)" }
        .onChange(of: server.settings.port) { _, newValue in
            // Keep the field in sync if the port changes elsewhere.
            if Int(portText) != newValue { portText = "\(newValue)" }
        }
        .sheet(isPresented: $showNewKeySheet) {
            NewKeySheet { name in
                generatedKey = server.settings.generateKey(name: name)
                showGeneratedKey = true
            }
        }
        .alert("API Key Generated", isPresented: $showGeneratedKey) {
            Button("Copy") {
                if let key = generatedKey {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.key, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if let key = generatedKey {
                Text("Key: \(key.key)\n\nCopy it now — it won't be shown again.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Text("MCP Server")
            .font(.title2.weight(.semibold))
    }

    // MARK: - Server card

    private var serverCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Enable MCP Server", isOn: Binding(
                        get: { server.settings.isEnabled },
                        set: { setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout.weight(.medium))

                    Spacer()

                    statusIndicator
                }

                if let error = server.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 20) {
                    field(label: "Port") {
                        TextField("3000", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit { commitPort() }
                    }
                    field(label: "Bind") {
                        Picker("", selection: Binding(
                            get: { server.settings.bindAddress },
                            set: { setBindAddress($0) }
                        )) {
                            Text("localhost (127.0.0.1)").tag("127.0.0.1")
                            Text("all interfaces (0.0.0.0)").tag("0.0.0.0")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    Spacer(minLength: 0)
                }

                Text(verbatim: "Endpoint: http://\(server.settings.bindAddress):\(server.settings.port)\(MCPConstants.endpoint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Button {
                        exportConfig()
                    } label: {
                        Label("Export Config", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                    .disabled(server.settings.apiKeys.isEmpty)
                    .help(server.settings.apiKeys.isEmpty
                          ? "Generate an API key first"
                          : "Export a .mcp.json client config using the first API key")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if server.isRunning {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.green.opacity(0.14), in: Capsule())
        } else {
            HStack(spacing: 5) {
                Circle().fill(.gray).frame(width: 7, height: 7)
                Text("Stopped")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.gray.opacity(0.14), in: Capsule())
        }
    }

    // MARK: - Keys card

    private var keysCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("API Keys", systemImage: "key.fill")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        showNewKeySheet = true
                    } label: {
                        Label("Generate Key", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                if server.settings.apiKeys.isEmpty {
                    Text("No API keys yet. Generate one and add it to your client's Authorization header to allow connections.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(server.settings.apiKeys.enumerated()), id: \.element.id) { index, key in
                        if index > 0 { Divider() }
                        keyRow(key)
                    }
                }
            }
        }
    }

    private func keyRow(_ key: MCPSettings.APIKey) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.callout.weight(.medium))
                Text("Created \(key.createdAt.formatted(Date.RelativeFormatStyle(presentation: .named).locale(Locale(identifier: "en_US"))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("••••" + key.key.suffix(6))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                server.settings.deleteKey(id: key.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete key")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Log card

    private var logCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Request Log", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))

                if server.requestLog.entries.isEmpty {
                    Text("No requests yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    Table(server.requestLog.entries) {
                        TableColumn("Time") { entry in
                            Text(entry.timestamp, style: .time)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .width(min: 60, ideal: 70)
                        TableColumn("Tool") { entry in
                            Text(entry.toolName)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .width(min: 120, ideal: 160)
                        TableColumn("Status") { entry in
                            Label(
                                entry.success ? "OK" : "FAIL",
                                systemImage: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .labelStyle(.iconOnly)
                            .foregroundStyle(entry.success ? .green : .red)
                            .help(entry.success ? "OK" : "Failed")
                        }
                        .width(50)
                        TableColumn("Duration") { entry in
                            Text(String(format: "%.0f ms", entry.duration * 1000))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 60, ideal: 80)
                        TableColumn("Error") { entry in
                            Text(entry.errorMessage ?? "—")
                                .font(.caption)
                                .foregroundStyle(entry.errorMessage != nil ? .red : .secondary)
                                .lineLimit(1)
                                .help(entry.errorMessage ?? "")
                        }
                    }
                    .frame(minHeight: 160, idealHeight: 220)
                }
            }
        }
    }

    // MARK: - Building blocks

    /// The app's standard neutral content card (matches RegistriesView).
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.gray.opacity(0.22), lineWidth: 1)
            }
    }

    private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Actions

    private func setEnabled(_ on: Bool) {
        server.settings.isEnabled = on
        server.settings.save()
        Task {
            if on {
                try? await server.start()
            } else {
                await server.stop()
            }
        }
    }

    private func commitPort() {
        guard let p = Int(portText), (1..<65536).contains(p) else {
            portText = "\(server.settings.port)"  // reject: restore last good value
            return
        }
        guard p != server.settings.port else { return }
        server.settings.port = p
        server.settings.save()
        Task { try? await server.restart() }
    }

    private func setBindAddress(_ address: String) {
        guard address != server.settings.bindAddress else { return }
        server.settings.bindAddress = address
        server.settings.save()
        Task { try? await server.restart() }
    }

    /// Export a `.mcp.json` client config (Claude Code / OpenCode shape) for the
    /// first API key. When bound to 0.0.0.0 the connect target is rewritten to
    /// 127.0.0.1 - a client on the same machine reaches localhost either way, and
    /// 0.0.0.0 is not a valid connect destination. For LAN/remote use, edit the
    /// exported file to point at the host's IP.
    private func exportConfig() {
        guard let key = server.settings.apiKeys.first else { return }
        let host = server.settings.bindAddress == "0.0.0.0" ? "127.0.0.1" : server.settings.bindAddress
        let endpoint = "http://\(host):\(server.settings.port)\(MCPConstants.endpoint)"
        let config: [String: Any] = [
            "mcpServers": [
                "icontainu": [
                    "url": endpoint,
                    "headers": ["Authorization": "Bearer \(key.key)"],
                ]
            ]
        ]
        let panel = NSSavePanel()
        panel.title = "Export MCP Config"
        panel.nameFieldStringValue = ".mcp.json"
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            // Best-effort: a failed write leaves the user at the save panel;
            // there's no dedicated error surface on this view, so stay silent.
        }
    }
}

/// Modal to name and generate a new API key. Uses the shared FormSheet scaffold
/// so it matches every other create/add sheet in the app.
private struct NewKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onGenerate: (String) -> Void

    var body: some View {
        FormSheet(
            icon: "key.fill",
            iconColor: .accentColor,
            title: "Generate API Key",
            subtitle: "Name it so you can tell which client is connecting."
        ) {
            LabeledSection(label: "Name") {
                TextField("e.g. My Claude Code", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Generate") { submit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        onGenerate(name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
