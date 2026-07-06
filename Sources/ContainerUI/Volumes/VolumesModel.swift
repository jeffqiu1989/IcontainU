import ContainerAPIClient
import ContainerResource
import Foundation
import Observation

@Observable
@MainActor
final class VolumesModel {
    private(set) var volumes: [VolumeConfiguration] = []
    private(set) var pollError: String?
    private(set) var lastError: OperationError?

    func clearError() { lastError = nil }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        do {
            volumes = try await ClientVolume.list().sorted { $0.name < $1.name }
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func create(name: String, size: String) async {
        lastError = nil
        do {
            try await createThrowing(name: name, size: size)
        } catch {
            lastError = OperationError(title: "Failed to create volume", detail: error.localizedDescription)
        }
    }

    /// Throwing core shared with the MCP layer.
    func createThrowing(name: String, size: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw InputError("Volume name is empty")
        }
        // A blank size uses the server default (512GB). A non-empty value is
        // passed through driverOpts["size"], mirroring the CLI's `--size`; the
        // server parses suffixes (K/M/G/T/P) and reports a bad value as an error.
        let trimmedSize = size.trimmingCharacters(in: .whitespaces)
        let driverOpts = trimmedSize.isEmpty ? [:] : ["size": trimmedSize]
        _ = try await ClientVolume.create(name: trimmed, driverOpts: driverOpts)
        await refresh()
    }

    func delete(_ volume: VolumeConfiguration) async {
        lastError = nil
        do {
            try await deleteThrowing(volume)
        } catch {
            lastError = OperationError(title: "Failed to delete volume", detail: error.localizedDescription)
        }
    }

    func deleteThrowing(_ volume: VolumeConfiguration) async throws {
        try await ClientVolume.delete(name: volume.name)
        await refresh()
    }
}
