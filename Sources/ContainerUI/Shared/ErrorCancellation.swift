import ContainerizationError
import Foundation

extension Error {
    /// True when this error represents cooperative cancellation.
    ///
    /// The `container` XPC clients (`MachineClient`, `ContainerClient`, …) wrap
    /// every failure — a cancellation included — into a
    /// `ContainerizationError(.internalError, cause: <CancellationError>)`, which
    /// renders as e.g. `failed to create container machine (cause:
    /// "CancellationError()")`. Because the wrapped value is a
    /// `ContainerizationError` rather than a `CancellationError`, a plain
    /// `catch is CancellationError` does not match it, and a user-initiated cancel
    /// surfaces as a spurious "Failed to …" error even though the operation was
    /// deliberately aborted.
    ///
    /// This walks the `cause` chain so a cancellation — raw or wrapped — is
    /// recognized as such. Use it in a catch arm to treat cancels as non-errors:
    ///
    ///     } catch {
    ///         guard !error.isCancellation else { return }
    ///         lastError = .from("Failed to create machine", error: error)
    ///     }
    var isCancellation: Bool {
        if self is CancellationError { return true }
        guard let error = self as? ContainerizationError else { return false }
        return error.code == .cancelled || (error.cause?.isCancellation ?? false)
    }

    /// True for transient image-pull failures worth an automatic retry:
    /// connect/read timeouts, connection resets. The `container` XPC clients
    /// wrap these in a `ContainerizationError` cause chain (same wrapping that
    /// hides cancellations), so walk the chain and string-match at each level —
    /// the underlying `HTTPClientError` arrives as a cause whose
    /// `String(describing:)` is e.g. `"connectTimeout"`.
    ///
    /// Non-transient failures (404, auth/403, arch mismatch) return false so the
    /// pull fails fast instead of wasting attempts that can't succeed.
    var isTransientPullError: Bool {
        if self is CancellationError { return false }
        return Self.anyCause(self) { $0.hasTransientPullMarker }
    }

    private static func anyCause(_ error: Error, _ test: (Error) -> Bool) -> Bool {
        if test(error) { return true }
        if let ce = error as? ContainerizationError, let cause = ce.cause {
            return anyCause(cause, test)
        }
        return false
    }

    private var hasTransientPullMarker: Bool {
        // `localizedDescription` folds the cause in for `ContainerizationError`
        // ("… (cause: \"connectTimeout\")"); `String(describing:)` covers cases
        // where the cause's description differs. Lowercased substring match.
        let desc = (self.localizedDescription + " " + String(describing: self)).lowercased()
        return desc.contains("connecttimeout") || desc.contains("readtimeout")
            || desc.contains("connection reset") || desc.contains("connectionreset")
            || desc.contains("timed out")
    }
}
