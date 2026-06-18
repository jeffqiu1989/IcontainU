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

/// A user-facing failure from an explicit action (start/stop/delete/create/pull).
///
/// Distinct from a transient polling error: an `OperationError` is set only by a
/// deliberate operation and is **never** cleared by background refresh — it stays
/// until the user dismisses it or starts another operation of the same kind. This
/// is what lets a failure stay on screen long enough to read and copy, instead of
/// being wiped by the next poll a second or two later.
struct OperationError: Identifiable, Equatable {
    let id = UUID()
    /// Short headline, e.g. "启动容器失败" / "拉取镜像失败".
    let title: String
    /// Full `error.localizedDescription`, shown untruncated and copyable.
    let detail: String

    /// The text placed on the pasteboard by the banner's copy button.
    var copyText: String { detail.isEmpty ? title : "\(title)\n\(detail)" }

    static func == (lhs: OperationError, rhs: OperationError) -> Bool {
        lhs.id == rhs.id
    }
}
