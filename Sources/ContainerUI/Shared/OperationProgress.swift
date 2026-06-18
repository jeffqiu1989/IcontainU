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
import TerminalProgress

/// Progress of a long operation (image fetch / unpack / container prepare),
/// shared by every model that runs one. Replaces the per-model `PullProgress` /
/// `CreateProgress` structs and their near-identical event reducers.
///
/// Two rules keep the bar honest without the wild swings of raw `current/total`.
///
/// 1. **Indeterminate below a floor.** An image fetch announces its real size
///    late: the index/platform manifests (a few KB) download fully — reading as
///    100% — *before* the big layers' total is known. We only show a percentage
///    once the total clears `determinateFloor`, so that bogus early 100% never
///    renders; until then the bar is an indeterminate flow line.
///
/// 2. **Monotonic only while the total is unchanged.** Within a fixed total the
///    fraction never steps back, absorbing the jitter of concurrent blob
///    downloads. When the total grows (a new layer batch is discovered) the
///    denominator genuinely changed, so we recompute honestly — the bar may step
///    back once, which the view eases over. (Naively clamping monotonic across a
///    total change locks the bar at the first 100% forever.)
///
/// A phase boundary (`beginPhase`) resets everything so each phase starts fresh.
struct OperationProgress {
    /// Human-facing phase label, set by the model at each phase boundary
    /// (e.g. "Pulling nginx:latest…", "Unpacking…").
    var phaseLabel: String = "Preparing…"
    var currentSize: Int64 = 0
    var totalSize: Int64 = 0

    /// The fraction the bar draws. See the type doc for the monotonic rule.
    private(set) var displayedFraction: Double = 0

    /// Totals below this are just manifests/configs, not real payload — treat as
    /// indeterminate so a fully-fetched tiny manifest doesn't read as 100%.
    private static let determinateFloor: Int64 = 1 << 20  // 1 MiB

    /// The instantaneous fraction implied by the byte counts (0 when no total).
    var rawFraction: Double {
        guard totalSize > 0 else { return 0 }
        return min(1.0, Double(currentSize) / Double(totalSize))
    }

    /// True once the real payload total is known and a percentage is meaningful.
    var isDeterminate: Bool { totalSize >= Self.determinateFloor }

    /// Begin a new phase: relabel and reset all counters and the baseline so the
    /// next phase starts from zero.
    mutating func beginPhase(_ label: String) {
        phaseLabel = label
        currentSize = 0
        totalSize = 0
        displayedFraction = 0
    }

    /// Fold a batch of progress events into the byte counts, then update the
    /// displayed fraction per the monotonic rule. Event descriptions are ignored
    /// on purpose — the model owns the phase label so it stays stable.
    mutating func apply(_ events: [ProgressUpdateEvent]) {
        let previousTotal = totalSize
        for event in events {
            switch event {
            case .setTotalSize(let value): totalSize = value
            case .addTotalSize(let value): totalSize += value
            case .setSize(let value): currentSize = value
            case .addSize(let value): currentSize += value
            default: break
            }
        }
        if totalSize > previousTotal {
            // Denominator changed — recompute honestly rather than lock high.
            displayedFraction = rawFraction
        } else {
            displayedFraction = max(displayedFraction, rawFraction)
        }
    }
}
