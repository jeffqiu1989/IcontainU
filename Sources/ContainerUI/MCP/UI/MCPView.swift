import SwiftUI

/// Control panel for the embedded MCP server: enable/disable, bind config, API
/// keys, and a live request log. Styled to match the app's other settings-style
/// screens (RegistriesView) — sectioned cards on a neutral surface, no material.
struct MCPView: View {
    @Environment(MCPServerManager.self) private var server
    @State private var showNewKeySheet = false
    @State private var generatedKey: MCPSettings.APIKey?
    @State private var showGeneratedKey = false
    @State private var exportKey: MCPSettings.APIKey?
    @State private var portText = ""
    @State private var detailEntry: MCPRequestLog.Entry?

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
        .sheet(item: $exportKey) { key in
            ExportConfigSheet(key: key, host: exportHost(), port: server.settings.port)
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key.key, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy key")
            Button {
                exportKey = key
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Export client config")
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
                        TableColumn("Key") { entry in
                            Text(entry.keyName ?? "-")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .width(min: 60, ideal: 90)
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
                        TableColumn("Details") { entry in
                            if entry.params == nil && entry.errorMessage == nil {
                                Text("-").font(.caption).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let err = entry.errorMessage {
                                        Text(Self.normalizeLogText(err))
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    Text("Details")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                        .underline()
                                        .onTapGesture { detailEntry = entry }
                                        .popover(isPresented: Binding(
                                            get: { detailEntry?.id == entry.id },
                                            set: { if !$0 { detailEntry = nil } }
                                        )) {
                                            logDetailPopover(entry)
                                        }
                                }
                            }
                        }
                        .width(min: 140, ideal: 220)
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

    private func exportHost() -> String {
        switch server.settings.bindAddress {
        case "127.0.0.1": return "localhost"
        case "0.0.0.0": return primaryLANIPv4() ?? "localhost"
        default: return server.settings.bindAddress
        }
    }

    /// Best-effort primary LAN IPv4 (wifi/ethernet), skipping loopback and the
    /// container bridge subnet (192.168.64.x). Returns nil if none is found.
    private func primaryLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var preferred: String?
        var fallback: String?
        for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = cursor.pointee
            guard let addrPtr = iface.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            if name == "lo0" { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addrPtr, socklen_t(addrPtr.pointee.sa_len),
                               &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if ip.hasPrefix("192.168.64.") { continue }
            if name.hasPrefix("en") { preferred = ip }
            else if fallback == nil { fallback = ip }
        }
        return preferred ?? fallback
    }

    /// Popover content for a log row's "details" link: full params (YAML) +
    /// full error, scrollable and selectable so neither is lost to the table's
    /// single-line truncation.
    @ViewBuilder
    private func logDetailPopover(_ entry: MCPRequestLog.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(entry.toolName).font(.caption.weight(.semibold))
                    if let key = entry.keyName {
                        Text("key: \(key)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.0f ms", entry.duration * 1000))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let params = entry.params {
                    Text("Parameters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(params)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let err = entry.errorMessage {
                    if entry.params != nil { Divider() }
                    Text("Error").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    Text(Self.normalizeLogText(err))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: 480)
        }
        .frame(maxHeight: 360)
    }

    /// Normalize line endings in a log error string: CLI tools (redis-cli,
    /// kafka) emit CRLF, and a lone CR renders as a stray box. Collapse to \n.
    private static func normalizeLogText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
         .replacingOccurrences(of: "\r", with: "\n")
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

/// Sheet showing a ready-to-paste `.mcp.json` client config (Claude Code shape)
/// for one API key. The token is embedded inline in the Authorization header.
private struct ExportConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let key: MCPSettings.APIKey
    let host: String
    let port: Int
    @State private var copied = false

    private var configText: String {
        let endpoint = "http://\(host):\(port)\(MCPConstants.endpoint)"
        return """
        {
          "mcpServers": {
            "icontainu": {
              "type": "streamable-http",
              "url": "\(endpoint)",
              "headers": {
                "Authorization": "Bearer \(key.key)"
              }
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MCP Client Config", systemImage: "doc.text")
                .font(.headline)
            Text("Paste this into your client's .mcp.json (Claude Code). The key is embedded in the Authorization header.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(configText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxHeight: 220)
            HStack {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configText, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
