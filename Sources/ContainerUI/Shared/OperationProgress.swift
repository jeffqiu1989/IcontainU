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
///
/// This is a reference type (`@Observable @MainActor final class`) so progress
/// events fold into the instance in place (`apply` mutates `self`). The value-type
/// copy-then-writeback it replaced discarded accumulated bytes whenever a reducer
/// chose not to write back (a throttle-on-read bug that made the kernel download
/// bar read as indeterminate). `InlineProgressBar` observes the instance directly,
/// so a property change drives the UI without the owning model re-publishing it.
@Observable
@MainActor
final class OperationProgress {
    /// Human-facing phase label, set at each phase boundary
    /// (e.g. "Pulling nginx:latest…", "Unpacking…").
    var phaseLabel: String
    private(set) var currentSize: Int64 = 0
    private(set) var totalSize: Int64 = 0

    /// The fraction the bar draws. See the type doc for the monotonic rule.
    private(set) var displayedFraction: Double = 0

    /// Totals below this are just manifests/configs, not real payload — treat as
    /// indeterminate so a fully-fetched tiny manifest doesn't read as 100%.
    private static let determinateFloor: Int64 = 1 << 20  // 1 MiB

    /// Once an "unpack" phase is detected the CLI resets its byte counters, which
    /// would make the bar jump backward. From then on we keep only the phase
    /// label and suppress byte updates. `apply` flips this on the first
    /// `setDescription` containing "unpack" and `beginPhase`s into it — the kernel
    /// download relies on this; pulls/creates simply don't emit such a description.
    private var unpacking = false

    init(phaseLabel: String = "Preparing…") {
        self.phaseLabel = phaseLabel
    }

    /// The instantaneous fraction implied by the byte counts (0 when no total).
    var rawFraction: Double {
        guard totalSize > 0 else { return 0 }
        return min(1.0, Double(currentSize) / Double(totalSize))
    }

    /// True once the real payload total is known and a percentage is meaningful.
    var isDeterminate: Bool { totalSize >= Self.determinateFloor }

    /// Begin a new phase: relabel and reset all counters and the baseline so the
    /// next phase starts from zero.
    func beginPhase(_ label: String) {
        phaseLabel = label
        currentSize = 0
        totalSize = 0
        displayedFraction = 0
    }

    /// Fold a batch of progress events into the byte counts, then update the
    /// displayed fraction per the monotonic rule. An "unpack" description flips
    /// into the unpack phase (label only, byte events suppressed) — see
    /// `unpacking`.
    func apply(_ events: [ProgressUpdateEvent]) {
        // Detect the unpack phase boundary first. Once entered, byte counters are
        // CLI-reset and meaningless — keep only the phase label from then on.
        for event in events {
            if case .setDescription(let desc) = event, desc.lowercased().contains("unpack") {
                unpacking = true
                beginPhase(desc)
            }
        }

        if unpacking {
            for event in events {
                if case .setDescription(let desc) = event {
                    phaseLabel = desc
                }
            }
            return
        }

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
