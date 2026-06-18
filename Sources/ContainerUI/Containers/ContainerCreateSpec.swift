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

import Foundation

/// User-provided inputs from the create-container form. Mirrors the subset of
/// `container run` flags the GUI exposes; everything else uses defaults.
///
/// The GUI always runs the container detached (`-d`) using the image's own
/// default command — it intentionally does not expose command/entrypoint editing
/// because there is no built-in terminal to interact with an overridden process.
struct ContainerCreateSpec {
    /// Image reference (e.g. "nginx:latest").
    var image: String
    /// Container name; nil auto-generates one.
    var name: String?
    /// Command tokens (argv). Empty keeps the image default. Per OCI semantics,
    /// when the image has an entrypoint these become its arguments; otherwise they
    /// are the command to execute.
    var command: [String] = []
    /// Port publishings in CLI form, e.g. "8080:80/tcp".
    var publishPorts: [String] = []
    /// Volume binds / mounts in CLI form, e.g. "/host:/data:ro" or "vol:/data".
    var volumes: [String] = []
    /// Environment variables in "KEY=VALUE" form.
    var env: [String] = []
    /// Networks to attach to. Empty uses the built-in default network; "none"
    /// disables networking; otherwise each entry is a named network.
    var networks: [String] = []
    /// Remove the container automatically when it stops (`--rm`).
    var autoRemove: Bool = false
    /// Forward the host SSH agent socket (`--ssh`).
    var ssh: Bool = false
}
