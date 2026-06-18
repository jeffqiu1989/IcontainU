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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Logging

/// Analyzes a local image to distill an `ImageMetadata` for pre-filling the
/// create-container form. Reads everything from local content-store blobs — OCI
/// config, history (EXPOSE/VOLUME), and the entrypoint script extracted directly
/// from a layer — without ever booting a container.
enum ImageInspector {
    private static let log = Logger(label: "container-ui.inspect")

    static func analyze(image: ClientImage, platform: Platform) async throws -> ImageMetadata {
        var meta = ImageMetadata()

        // 1. OCI config — command, entrypoint, workdir, user, env, labels.
        let ociImage = try await image.config(for: platform)
        if let config = ociImage.config {
            meta.command = config.cmd ?? []
            meta.entrypoint = config.entrypoint ?? []
            meta.workingDir = config.workingDir
            meta.user = config.user
            meta.stopSignal = config.stopSignal
            meta.labels = config.labels ?? [:]
            meta.buildEnv = (config.env ?? []).compactMap { Self.parseEnv($0) }
            log.debug(
                "OCI config",
                metadata: [
                    "entrypoint": "\(config.entrypoint ?? [])",
                    "cmd": "\(config.cmd ?? [])",
                    "buildEnvCount": "\(meta.buildEnv.count)",
                ])
        }

        // 2. History — EXPOSE / VOLUME (not present in the decoded OCI config).
        if let history = ociImage.history {
            for entry in history {
                guard let createdBy = entry.createdBy else { continue }
                meta.exposedPorts.append(contentsOf: Self.parseExpose(createdBy))
                meta.volumes.append(contentsOf: Self.parseVolume(createdBy))
            }
            meta.exposedPorts = Array(Set(meta.exposedPorts)).sorted()
            meta.volumes = Array(Set(meta.volumes)).sorted()
        }

        // 3. Entrypoint script — user-facing env vars (best effort; skipped for
        //    binary entrypoints that aren't shell scripts).
        do {
            if let script = try await Self.readEntrypointScript(image: image, platform: platform, ociImage: ociImage) {
                meta.userEnv = Self.extractEnvVars(fromScript: script)
                log.debug(
                    "extracted user env from entrypoint",
                    metadata: ["count": "\(meta.userEnv.count)", "vars": "\(meta.userEnv)"])
            } else {
                log.debug("no entrypoint script resolved; userEnv left empty")
            }
        } catch {
            log.warning("entrypoint script read failed", metadata: ["error": "\(error)"])
        }

        return meta
    }

    // MARK: - Layer entrypoint extraction

    /// Reads the entrypoint shell script straight out of the image layers.
    private static func readEntrypointScript(
        image: ClientImage, platform: Platform, ociImage: ContainerizationOCI.Image
    ) async throws -> String? {
        // Resolve the entrypoint file path from the OCI config.
        guard let entrypointPath = Self.entrypointFilePath(ociImage) else { return nil }
        let target = entrypointPath.hasPrefix("/") ? String(entrypointPath.dropFirst()) : entrypointPath

        // Match on the basename: the OCI entrypoint is often just
        // "docker-entrypoint.sh" while the tar entry is "usr/local/bin/docker-entrypoint.sh".
        let targetName = (target as NSString).lastPathComponent
        log.debug("searching layers for entrypoint script", metadata: ["target": "\(target)", "basename": "\(targetName)"])

        let manifest = try await image.manifest(for: platform)
        let contentStore = RemoteContentStoreClient()

        // Search layers from top (last) to bottom so upper layers win.
        for descriptor in manifest.layers.reversed() {
            guard let content = try? await contentStore.get(digest: descriptor.digest) else { continue }
            if let script = Self.extractTextFile(fromLayer: content.path, basename: targetName) {
                log.debug("found entrypoint script", metadata: ["layer": "\(descriptor.digest)", "bytes": "\(script.count)"])
                return script
            }
        }
        log.debug("entrypoint script not found in any layer", metadata: ["basename": "\(targetName)"])
        return nil
    }

    /// Pull the entrypoint binary/script path from the OCI config.
    private static func entrypointFilePath(_ ociImage: ContainerizationOCI.Image) -> String? {
        guard let entrypoint = ociImage.config?.entrypoint, let first = entrypoint.first else {
            return nil
        }
        // Only shell-ish scripts are worth reading; skip obvious binaries.
        let isScript =
            first.hasSuffix(".sh")
            || first.contains("entrypoint")
            || first.contains("/bin/")
            || first.contains("start-script")
            || first.contains("run.sh")
        guard isScript else { return nil }
        return first
    }

    /// Extract a file from a gzip+tar layer blob by matching its basename,
    /// returning it as UTF-8 text. Iterates entries because the OCI entrypoint is
    /// frequently an unqualified name (e.g. "docker-entrypoint.sh") while the tar
    /// stores a full path (e.g. "usr/local/bin/docker-entrypoint.sh"). Returns nil
    /// if no entry matches or the contents aren't valid text.
    private static func extractTextFile(fromLayer layerURL: URL, basename: String) -> String? {
        guard let reader = try? ArchiveReader(file: layerURL) else { return nil }
        for (entry, data) in reader {
            guard let path = entry.path else { continue }
            guard (path as NSString).lastPathComponent == basename else { continue }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    // MARK: - Parsing helpers

    private static func parseEnv(_ raw: String) -> ImageMetadata.EnvVar? {
        guard let idx = raw.firstIndex(of: "=") else { return nil }
        return .init(key: String(raw[..<idx]), value: String(raw[raw.index(after: idx)...]))
    }

    /// Parse `EXPOSE map[80/tcp:{} 443/tcp:{}]` from a history `created_by` line.
    static func parseExpose(_ line: String) -> [String] {
        guard line.contains("EXPOSE") else { return [] }
        let pattern = #"(\d+/(?:tcp|udp))"#
        return Self.matches(pattern, in: line)
    }

    /// Parse `VOLUME [/var/lib/mysql /data]` from a history `created_by` line.
    static func parseVolume(_ line: String) -> [String] {
        guard line.contains("VOLUME") else { return [] }
        let pattern = #"(/[^\s\]\[]+)"#
        return Self.matches(pattern, in: line)
    }

    /// Extract candidate user environment variables from a shell entrypoint:
    ///   - `file_env 'VAR'`            (the standard docker-library pattern)
    ///   - `[ -z "$VAR" ]` / `-n`      (existence checks)
    /// Filters out common shell and internal variables.
    static func extractEnvVars(fromScript script: String) -> [String] {
        var found: Set<String> = []
        found.formUnion(Self.matches(#"file_env\s+'([A-Z_][A-Z0-9_]+)'"#, in: script, group: 1))
        found.formUnion(Self.matches(#"-[zn]\s+"?\$\{?([A-Z_][A-Z0-9_]+)"#, in: script, group: 1))

        let denylist: Set<String> = [
            "PATH", "HOME", "USER", "UID", "GID", "HOSTNAME", "SHELL", "TERM", "PWD",
            "DATABASE_ALREADY_EXISTS", "SOCKET", "DATADIR", "OLD_DATABASES", "VAR",
            "XYZ_DB_PASSWORD", "BASH_SOURCE",
        ]
        return found.subtracting(denylist).sorted()
    }

    /// Return all capture-group matches (or whole match if group == 0).
    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let groupIdx = match.numberOfRanges > group ? group : 0
            guard let r = Range(match.range(at: groupIdx), in: text) else { return nil }
            return String(text[r])
        }
    }
}
