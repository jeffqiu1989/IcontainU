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
}
