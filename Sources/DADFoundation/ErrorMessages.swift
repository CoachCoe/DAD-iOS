import Foundation

extension Error {
    /// The one user-facing sentence every donor/partner model shows for a failed call. Detail
    /// stays out of the UI on purpose: server error bodies are not user copy and may be sensitive.
    var userMessage: String {
        if let account = self as? AccountError, account == .signedOut { return "Please sign in again." }
        return "Something went wrong. Please try again."
    }
}
