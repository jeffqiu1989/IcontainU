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

/// A parsed OCI image reference split into a short repository name and tag, for
/// display. This is a lightweight, IO-free approximation of the CLI's
/// `denormalizeReference` — it strips the default registry/library prefixes that
/// add noise in the UI (`docker.io/library/nginx:1.27` → repo `nginx`, tag `1.27`).
struct ParsedImageReference {
    let repository: String
    let tag: String?

    init(_ reference: String) {
        var ref = reference

        // Split off the digest (if any) before the tag, to avoid mistaking the
        // digest's colon for a tag separator.
        if let atIndex = ref.firstIndex(of: "@") {
            ref = String(ref[..<atIndex])
        }

        // Split repository and tag on the last colon — but only if that colon is
        // in the final path segment, since a registry host may include a port
        // (e.g. `localhost:5000/app`).
        var repo = ref
        var parsedTag: String?
        if let colonIndex = ref.lastIndex(of: ":"),
            let slashIndex = ref.lastIndex(of: "/")
        {
            if colonIndex > slashIndex {
                repo = String(ref[..<colonIndex])
                parsedTag = String(ref[ref.index(after: colonIndex)...])
            }
        } else if let colonIndex = ref.lastIndex(of: ":"), !ref.contains("/") {
            repo = String(ref[..<colonIndex])
            parsedTag = String(ref[ref.index(after: colonIndex)...])
        }

        // Drop the noisy default registry / library prefixes.
        for prefix in ["docker.io/library/", "docker.io/", "library/"] {
            if repo.hasPrefix(prefix) {
                repo.removeFirst(prefix.count)
                break
            }
        }

        self.repository = repo
        self.tag = parsedTag
    }
}
