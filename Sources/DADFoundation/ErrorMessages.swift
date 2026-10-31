import Foundation
import OpenAPIRuntime

extension Error {
    /// True for Swift task cancellation and URLSession's cancelled error: the work was abandoned
    /// (view left, task replaced), not failed, so models keep their prior state instead of erroring.
    var isCancellation: Bool {
        if let client = self as? ClientError { return client.underlyingError.isCancellation }
        return self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    /// The one user-facing sentence every donor/partner model shows for a failed call. Detail
    /// stays out of the UI on purpose: server error bodies are not user copy and may be sensitive.
    var userMessage: String {
        if let account = self as? AccountError {
            switch account {
            case .signedOut: return "Please sign in again."
            case .rateLimited: return "Too many attempts. Please wait a moment and try again."
            case .deletionBlocked:
                return "We can’t delete your account while a monthly gift is active or a checkout is open. Cancel your monthly gift first, then try again."
            case .forbidden: return "Giving isn’t available for this account."
            case .conflict: return "Your gift changed while you were looking at it. We’ve refreshed it; please review and try again."
            case .paymentsUnavailable: return "Payments aren’t available right now. Please try again later."
            default: break
            }
        }
        return "Something went wrong. Please try again."
    }
}
