import AppKit
import Observation
import os
import SwiftUI

/// A bounded, thread-safe line buffer for streaming logs (build output, etc.).
///
/// Producers (background PTY readers) call `append(_:)` from any thread at any
/// rate; the buffer coalesces lines and publishes to observers at most every
/// `flushInterval` on the main actor. This is what keeps a chatty BuildKit build
/// (hundreds of TTY-redraw lines per second) from flooding the main thread — the
/// old per-line `Task { @MainActor }` hop was the primary freeze cause.
///
/// Bounded: only the most recent `maxLines` are retained (ring semantics — old
/// lines are dropped from the head), so memory stays flat on any log size.
@Observable
@MainActor
final class LogBuffer {
    /// Monotonic count of lines ever flushed (not capped). Observers use the
    /// delta since their last sync to know exactly how many new lines arrived,
    /// even across head-trims. Also serves as the change signal for @Observable.
    private(set) var totalFlushed = 0

    /// Retained lines, oldest first, capped at `maxLines`.
    private(set) var lines: [String] = []

    /// True once `close()` is called — no more lines will arrive. The console
    /// uses this to stop its follow behavior for finished builds.
    private(set) var isClosed = false

    /// Bumped on `reset()` so a console can tell "new stream" from "more lines".
    private(set) var generation = 0

    private let maxLines: Int
    private let flushInterval: Duration

    /// Pending lines accumulated off the main actor between flushes.
    private let pending = OSAllocatedUnfairLock(initialState: [String]())
    private var flushTask: Task<Void, Never>?

    init(maxLines: Int = 2000, flushInterval: Duration = .milliseconds(100)) {
        self.maxLines = maxLines
        self.flushInterval = flushInterval
    }

    /// Append a line from any thread. Cheap: takes a lock, appends to the pending
    /// batch, and schedules a flush if none is pending.
    nonisolated func append(_ line: String) {
        pending.withLock { $0.append(line) }
        Task { @MainActor in
            self.scheduleFlush()
        }
    }

    /// Mark the stream finished and flush whatever remains immediately.
    func close() {
        flushTask?.cancel()
        flushTask = nil
        flushNow()
        isClosed = true
    }

    /// Reset for a new stream (new build reusing the same console).
    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pending.withLock { $0.removeAll() }
        lines.removeAll()
        isClosed = false
        totalFlushed = 0
        generation &+= 1
    }

    /// Replace the whole content with a static snapshot (viewing a persisted
    /// log tail from a finished build).
    func load(snapshot: [String]) {
        reset()
        lines = Array(snapshot.suffix(maxLines))
        totalFlushed = lines.count
        isClosed = true
    }

    /// The whole buffer as one string (for copy / failure tails).
    var text: String { lines.joined(separator: "\n") }

    /// The last `count` lines — used for persisted failure tails.
    func tail(_ count: Int) -> [String] {
        Array(lines.suffix(count))
    }

    // MARK: - Flushing

    /// Schedule a single delayed flush. Multiple appends within the interval
    /// coalesce into one main-actor publish.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [flushInterval] in
            try? await Task.sleep(for: flushInterval)
            guard !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushNow()
        }
    }

    private func flushNow() {
        let batch = pending.withLock { batch in
            defer { batch.removeAll() }
            return batch
        }
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        totalFlushed &+= batch.count
    }
}

/// A monospaced, read-only log console backed by `NSTextView`.
///
/// Why AppKit and not SwiftUI `Text`/`ForEach`: `NSTextView` renders lazily (only
/// visible lines are laid out) and appending text does not re-diff a view tree.
/// The previous SwiftUI console re-rendered every line on every append — O(n) per
/// append, O(n²) overall — which is what froze the app during chatty builds.
///
/// Follow behavior: while the user is at (or near) the bottom, new content keeps
/// the view pinned to the end. Scrolling up pauses following (the view stays
/// where the user put it); scrolling back to the bottom resumes it. Closed
/// buffers (finished builds) render as a static snapshot.
struct LogConsoleView: NSViewRepresentable {
    let buffer: LogBuffer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        // Track user scrolling to pause/resume follow.
        context.coordinator.attach(scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Reading these registers the @Observable dependency, so SwiftUI calls
        // updateNSView again on the next flush / reset.
        let total = buffer.totalFlushed
        let generation = buffer.generation
        context.coordinator.sync(
            lines: buffer.lines, totalFlushed: total, generation: generation, into: scrollView)
    }

    @MainActor
    final class Coordinator {
        /// `totalFlushed` at our last sync — the delta tells us exactly how many
        /// new lines arrived, robust across ring head-trims (where `lines.count`
        /// stays constant while content shifts).
        private var syncedTotal = 0
        /// Buffer generation at last sync; a change means reset -> full reload.
        private var syncedGeneration = -1
        /// Rendered line count in the text view. Grows past the buffer's cap
        /// between full reloads (we only append deltas); periodically trimmed.
        private var renderedLines = 0
        /// Hard cap on text-view lines before we force a full reload from the
        /// buffer, keeping the document bounded (~2x buffer cap).
        private let renderedCap = 4000

        private var following = true
        /// `nonisolated(unsafe)` so deinit (nonisolated in Swift 6) can remove it.
        /// Safe: written once from the main actor in `attach`, read in deinit
        /// after all main-actor use has ceased.
        private nonisolated(unsafe) var scrollObserver: NSObjectProtocol?

        func attach(scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    // At (or within ~2 lines of) the bottom -> follow; above -> pause.
                    self.following = Self.isAtBottom(scrollView)
                }
            }
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func sync(lines: [String], totalFlushed: Int, generation: Int, into scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView,
                let storage = textView.textStorage
            else { return }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(
                    ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]

            let newLines = totalFlushed - syncedTotal
            let needsReload =
                generation != syncedGeneration  // buffer reset (new stream / snapshot)
                || newLines >= lines.count      // we missed more than the buffer holds
                || renderedLines + newLines > renderedCap  // document grew too long

            if needsReload {
                storage.setAttributedString(
                    NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs))
                renderedLines = lines.count
            } else if newLines > 0 {
                // Append exactly the lines that arrived since last sync — they're
                // the buffer's tail regardless of head-trimming.
                let delta = lines.suffix(newLines).joined(separator: "\n")
                let prefix = renderedLines > 0 ? "\n" : ""
                storage.append(NSAttributedString(string: prefix + delta, attributes: attrs))
                renderedLines += newLines
            } else {
                return  // nothing new
            }

            syncedTotal = totalFlushed
            syncedGeneration = generation

            if following {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            let visible = scrollView.contentView.bounds
            guard let doc = scrollView.documentView else { return true }
            // Within ~2 line-heights of the end counts as "at the bottom".
            return visible.maxY >= doc.bounds.maxY - 30
        }
    }
}
