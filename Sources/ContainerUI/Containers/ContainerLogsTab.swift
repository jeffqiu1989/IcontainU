import ContainerAPIClient
import Foundation
import Observation
import SwiftUI

/// Loads and (optionally) follows a container's stdout log. Reading a FileHandle
/// is blocking I/O, so the initial read runs off the main actor; follow uses the
/// handle's readability callback to append new output.
@Observable
@MainActor
final class ContainerLogsModel {
    private(set) var text: String = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var following = false {
        didSet { following ? startFollowing() : stopFollowing() }
    }

    private let containerID: String
    // Fresh client per use (cached XPC connections go invalid across apiserver
    // restarts). See ContainersModel for the rationale.
    private var client: ContainerClient { ContainerClient() }
    private var followHandle: FileHandle?

    init(containerID: String) {
        self.containerID = containerID
    }

    /// One-shot load of the full stdout log.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let handles = try await client.logs(id: containerID)
            guard let stdout = handles.first else {
                text = ""
                return
            }
            let data = try await Task.detached { try stdout.readToEnd() }.value
            if let data, let str = String(data: data, encoding: .utf8) {
                text = str
            } else {
                text = ""
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startFollowing() {
        Task {
            do {
                let handles = try await client.logs(id: containerID)
                guard let stdout = handles.first else { return }
                try stdout.seekToEnd()
                followHandle = stdout
                stdout.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
                    Task { @MainActor [weak self] in
                        self?.text += str
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                following = false
            }
        }
    }

    private func stopFollowing() {
        followHandle?.readabilityHandler = nil
        followHandle = nil
    }

    func cleanup() {
        stopFollowing()
    }
}

/// The Logs tab: shows stdout, with refresh and a follow toggle.
struct ContainerLogsTab: View {
    let containerID: String
    @State private var model: ContainerLogsModel

    init(containerID: String) {
        self.containerID = containerID
        _model = State(initialValue: ContainerLogsModel(containerID: containerID))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }
            logContent
            Divider()
            controls
        }
        .task {
            await model.load()
        }
        .onDisappear {
            model.cleanup()
        }
    }

    @ViewBuilder
    private var logContent: some View {
        if model.isLoading && model.text.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.text.isEmpty {
            ContentUnavailableView("No Logs", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("logEnd")
                }
                .onChange(of: model.text) {
                    if model.following {
                        proxy.scrollTo("logEnd", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Toggle("Follow", isOn: Binding(get: { model.following }, set: { model.following = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button {
                copyToClipboard(model.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(model.text.isEmpty)
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.following)
        }
        .padding(10)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
