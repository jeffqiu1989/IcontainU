import SwiftUI

struct MCPView: View {
    @Environment(MCPServerManager.self) private var server
    @State private var showNewKeySheet = false
    @State private var newKeyName = ""
    @State private var generatedKey: MCPSettings.APIKey?
    @State private var showGeneratedKey = false
    @State private var portText = ""
    @State private var selectedAddress = "127.0.0.1"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                serverSection
                keysSection
                logSection
            }
            .padding()
        }
        .navigationTitle("MCP Server")
        .onAppear {
            portText = "\(server.settings.port)"
            selectedAddress = server.settings.bindAddress
        }
        .sheet(isPresented: $showNewKeySheet) {
            newKeySheet
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

    // MARK: - Server Section

    @ViewBuilder
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server", systemImage: "server.rack")
                .font(.headline)

            HStack {
                Toggle("Enable MCP Server", isOn: Binding(
                    get: { server.settings.isEnabled },
                    set: { newValue in
                        server.settings.isEnabled = newValue
                        server.settings.save()
                        if newValue {
                            Task { try? await server.start() }
                        } else {
                            Task { await server.stop() }
                        }
                    }
                ))

                Spacer()

                if server.isRunning {
                    Label("Running", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else if let error = server.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Text("Port")
                    .frame(width: 80, alignment: .trailing)
                TextField("3000", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit {
                        if let p = Int(portText), p > 0, p < 65536 {
                            server.settings.port = p
                            server.settings.save()
                        }
                    }

                Spacer()

                Text("Bind")
                    .frame(width: 40, alignment: .trailing)
                Picker("", selection: $selectedAddress) {
                    Text("localhost (127.0.0.1)").tag("127.0.0.1")
                    Text("all interfaces (0.0.0.0)").tag("0.0.0.0")
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: selectedAddress) { _, newValue in
                    server.settings.bindAddress = newValue
                    server.settings.save()
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Keys Section

    @ViewBuilder
    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("API Keys", systemImage: "key")
                    .font(.headline)
                Spacer()
                Button("Generate Key") {
                    newKeyName = ""
                    showNewKeySheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if server.settings.apiKeys.isEmpty {
                Text("No API keys. Generate one to allow remote connections.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(server.settings.apiKeys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                                .font(.body.weight(.medium))
                            Text("Created \(key.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(repeating: "•", count: 8) + key.key.suffix(8))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            server.settings.deleteKey(id: key.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Log Section

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Request Log", systemImage: "text.book.closed")
                .font(.headline)

            if server.requestLog.entries.isEmpty {
                Text("No requests yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
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
                        .foregroundStyle(entry.success ? .green : .red)
                        .font(.caption)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Duration") { entry in
                        Text(String(format: "%.0fms", entry.duration * 1000))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Error") { entry in
                        Text(entry.errorMessage ?? "—")
                            .font(.caption)
                            .foregroundStyle(entry.errorMessage != nil ? .red : .secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 150, idealHeight: 200)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - New Key Sheet

    @ViewBuilder
    private var newKeySheet: some View {
        VStack(spacing: 16) {
            Text("Generate API Key")
                .font(.headline)
            TextField("Key name (e.g. 'My Claude Code')", text: $newKeyName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    showNewKeySheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    let name = newKeyName.isEmpty ? "API Key" : newKeyName
                    generatedKey = server.settings.generateKey(name: name)
                    showNewKeySheet = false
                    showGeneratedKey = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newKeyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}
