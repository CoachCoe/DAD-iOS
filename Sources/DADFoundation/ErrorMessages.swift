import Foundation

extension Error {
    /// True for Swift task cancellation and URLSession's cancelled error: the work was abandoned
    /// (view left, task replaced), not failed, so models keep their prior state instead of erroring.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    /// The one user-facing sentence every donor/partner model shows for a failed call. Detail
    /// stays out of the UI on purpose: server error bodies are not user copy and may be sensitive.
    var userMessage: String {
        if let account = self as? AccountError, account == .signedOut { return "Please sign in again." }
        return "Something went wrong. Please try again."
    }
}
