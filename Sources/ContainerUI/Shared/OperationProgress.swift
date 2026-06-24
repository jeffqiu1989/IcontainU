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
///
/// **Publish throttling.** Raw byte counts always accumulate into private fields
/// on every event (so nothing is ever lost — the distinction from the old bug).
/// The *observed* properties the view reads are only refreshed at most once per
/// `publishInterval`, so the numbers tick at a calm, readable rate instead of
/// flickering many times a second. Phase changes and reaching 100% publish
/// immediately so the bar never looks stuck or stalls short of done.
@Observable
@MainActor
final class OperationProgress {
    /// Human-facing phase label, set at each phase boundary
    /// (e.g. "Pulling nginx:latest…", "Unpacking…"). Published immediately.
    var phaseLabel: String

    /// Observed byte counts and fraction the view renders. These lag the raw
    /// accumulators below by at most `publishInterval` (see `publishIfDue`).
    private(set) var currentSize: Int64 = 0
    private(set) var totalSize: Int64 = 0
    private(set) var displayedFraction: Double = 0

    /// Raw accumulators updated on every event. The published properties above
    /// are synced from these on a throttle. Keeping accumulation separate from
    /// publishing is what makes throttling safe: skipping a publish never drops
    /// bytes, it only defers showing them.
    private var rawCurrentSize: Int64 = 0
    private var rawTotalSize: Int64 = 0
    private var rawFractionValue: Double = 0
    private var lastPublish: Date = .distantPast

    /// Minimum spacing between UI publishes — ~4 updates/second reads as smooth
    /// without flickering digits.
    private static let publishInterval: TimeInterval = 0.25

    /// Totals below this are just manifests/configs, not real payload — treat as
    /// indeterminate so a fully-fetched tiny manifest doesn't read as 100%.
    private static let determinateFloor: Int64 = 1 << 20  // 1 MiB

    /// When true, a `setDescription` containing "unpack" switches the bar into an
    /// unpack phase: the label follows the description and byte events are
    /// suppressed (the CLI resets its counters across that boundary, which would
    /// otherwise make the bar jump backward). This is **opt-in** and only the
    /// kernel download enables it. Image pull / container create leave it off so
    /// their phase labels stay owned by the model — otherwise the init image's
    /// "Unpacking init image" description would hijack the "Preparing container…"
    /// label on every create, and pull's unpack-phase byte progress would be
    /// suppressed.
    private let tracksUnpackPhase: Bool
    private var unpacking = false

    init(phaseLabel: String = "Preparing…", tracksUnpackPhase: Bool = false) {
        self.phaseLabel = phaseLabel
        self.tracksUnpackPhase = tracksUnpackPhase
    }

    /// True once the real payload total is known and a percentage is meaningful.
    var isDeterminate: Bool { totalSize >= Self.determinateFloor }

    /// Begin a new phase: relabel and reset all counters and the baseline so the
    /// next phase starts from zero. Publishes immediately so the new phase shows
    /// without waiting on the throttle.
    func beginPhase(_ label: String) {
        phaseLabel = label
        rawCurrentSize = 0
        rawTotalSize = 0
        rawFractionValue = 0
        currentSize = 0
        totalSize = 0
        displayedFraction = 0
        lastPublish = .distantPast
    }

    /// Fold a batch of progress events into the raw byte counts, then publish to
    /// the observed properties on a throttle. When `tracksUnpackPhase` is set, an
    /// "unpack" description flips into the unpack phase (label only, byte events
    /// suppressed) — see `tracksUnpackPhase`.
    func apply(_ events: [ProgressUpdateEvent]) {
        if tracksUnpackPhase {
            // Detect the unpack phase boundary first. Once entered, byte counters
            // are CLI-reset and meaningless — keep only the phase label.
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
        }

        let previousTotal = rawTotalSize
        for event in events {
            switch event {
            case .setTotalSize(let value): rawTotalSize = value
            case .addTotalSize(let value): rawTotalSize += value
            case .setSize(let value): rawCurrentSize = value
            case .addSize(let value): rawCurrentSize += value
            default: break
            }
        }
        let raw = rawTotalSize > 0 ? min(1.0, Double(rawCurrentSize) / Double(rawTotalSize)) : 0
        if rawTotalSize > previousTotal {
            // Denominator changed — recompute honestly rather than lock high.
            rawFractionValue = raw
        } else {
            rawFractionValue = max(rawFractionValue, raw)
        }

        publishIfDue()
    }

    /// Sync the observed properties from the raw accumulators, but only once per
    /// `publishInterval`. Three cases publish immediately regardless of the
    /// throttle: crossing the determinate floor (so the bar switches from spinner
    /// to a real percentage promptly), reaching 100% (so it never stalls at 99%),
    /// and the first publish of a phase (`lastPublish` reset to `.distantPast`).
    private func publishIfDue() {
        let now = Date()
        let crossedFloor = totalSize < Self.determinateFloor && rawTotalSize >= Self.determinateFloor
        let completed = rawFractionValue >= 1.0 && displayedFraction < 1.0
        guard crossedFloor || completed || now.timeIntervalSince(lastPublish) >= Self.publishInterval
        else { return }
        lastPublish = now
        currentSize = rawCurrentSize
        totalSize = rawTotalSize
        displayedFraction = rawFractionValue
    }
}
