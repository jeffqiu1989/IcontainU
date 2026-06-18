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

import ContainerPersistence

/// Loads the container system configuration the same way the CLI does, using the
/// default app-root / install-root TOML layers. Needed by image pull, which must
/// normalize references against the configured registry/DNS settings.
enum SystemConfig {
    static func load() async throws -> ContainerSystemConfig {
        try await ConfigurationLoader.load()
    }
}
