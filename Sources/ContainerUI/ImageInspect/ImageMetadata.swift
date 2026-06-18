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

import ContainerizationOCI
import Foundation

/// Configuration distilled from an image, used to pre-fill the create-container
/// form so the user doesn't have to consult documentation for ports, volumes and
/// environment variables.
struct ImageMetadata {
    /// Default command (OCI `Cmd`).
    var command: [String] = []
    /// Entrypoint (OCI `Entrypoint`).
    var entrypoint: [String] = []
    /// Working directory (OCI `WorkingDir`).
    var workingDir: String?
    /// Default user (OCI `User`).
    var user: String?
    /// Stop signal (OCI `StopSignal`).
    var stopSignal: String?
    /// Labels (OCI `Labels`).
    var labels: [String: String] = [:]

    /// Build-time env baked into the image (OCI `Env`) — mostly version metadata.
    var buildEnv: [EnvVar] = []
    /// Env vars the entrypoint script reads — the ones a user typically must set
    /// (e.g. MYSQL_ROOT_PASSWORD). Extracted heuristically from the entrypoint.
    var userEnv: [String] = []

    /// Ports the image declares via `EXPOSE` (from history), e.g. "80/tcp".
    var exposedPorts: [String] = []
    /// Volumes the image declares via `VOLUME` (from history), e.g. "/var/lib/mysql".
    var volumes: [String] = []

    struct EnvVar {
        var key: String
        var value: String
    }
}
