import Foundation
import Testing

@testable import ContainerUI

/// BuildConfigStore round-trip tests against a temp directory (the store takes an
/// injectable root so tests never touch the real Application Support).
@MainActor
struct BuildConfigStoreTests {

    private func makeStore() throws -> (BuildConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "icontainu-build-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (BuildConfigStore(root: dir), dir)
    }

    private func sampleRecord(name: String = "myapp") -> BuildConfigRecord {
        BuildConfigRecord(
            name: name,
            contextDirPath: "/proj/app",
            dockerfilePath: "/proj/app/Dockerfile",
            tags: ["myapp:latest"],
            platforms: ["linux/arm64"],
            noCache: false,
            buildArgs: ["ENV=prod"],
            target: "builder",
            labels: [],
            pull: false,
            source: .standalone,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastBuild: nil)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(sampleRecord())
        #expect(store.records.count == 1)
        let loaded = try #require(store.record(for: "myapp"))
        #expect(loaded.tags == ["myapp:latest"])
        #expect(loaded.target == "builder")
        #expect(loaded.source == .standalone)
        #expect(store.exists("myapp"))
        #expect(!store.exists("other"))
    }

    @Test func removeDeletesRecord() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(sampleRecord())
        store.remove(config: "myapp")
        #expect(store.records.isEmpty)
        #expect(store.record(for: "myapp") == nil)
    }

    @Test func composeSourceRoundTripsAndFilters() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = sampleRecord(name: "flask-web")
        record.source = .compose(project: "flask", service: "web")
        try store.save(record)
        try store.save(sampleRecord(name: "standalone-one"))

        let loaded = try #require(store.record(for: "flask-web"))
        #expect(loaded.isComposeDerived)
        #expect(loaded.source == .compose(project: "flask", service: "web"))

        let composeRecords = store.records(forComposeProject: "flask")
        #expect(composeRecords.map(\.name) == ["flask-web"])
    }

    @Test func lastBuildOutcomePersistsWithCappedTail() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = sampleRecord()
        record.lastBuild = BuildOutcome(
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            duration: 12.5,
            message: "RUN failed",
            logTail: (0..<500).map { "line \($0)" })  // over the 200 cap
        try store.save(record)

        let loaded = try #require(store.record(for: "myapp"))
        let outcome = try #require(loaded.lastBuild)
        #expect(outcome.status == .failed)
        #expect(outcome.logTail.count == BuildConfigStore.logTailLimit)
        #expect(outcome.logTail.last == "line 499")  // tail keeps the end
    }

    @Test func saveOverwritesExisting() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(sampleRecord())
        var updated = sampleRecord()
        updated.tags = ["myapp:v2"]
        try store.save(updated)

        #expect(store.records.count == 1)
        #expect(store.record(for: "myapp")?.tags == ["myapp:v2"])
    }
}
