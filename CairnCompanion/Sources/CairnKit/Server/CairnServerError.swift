import CairnProtocol
import Foundation

/// Why a 403 was refused. Authenticated, but not allowed (spec section 2.5, 13).
public enum ForbiddenReason: Sendable, Equatable {
    case adminRequired
    case funnelRefused
    case tailnetIdentityRequired
    case scope
    case vehicleRequired
    case assignmentRefused
    case noStorageKey
    case enrolmentRefused
    case other(String)

    public init(code: String) {
        switch code {
        case "admin_required": self = .adminRequired
        case "funnel_refused": self = .funnelRefused
        case "tailnet_identity_required": self = .tailnetIdentityRequired
        case "scope": self = .scope
        case "vehicle_required": self = .vehicleRequired
        case "assignment_refused": self = .assignmentRefused
        case "no_storage_key": self = .noStorageKey
        case "enrolment_refused": self = .enrolmentRefused
        default: self = .other(code)
        }
    }

    public var code: String {
        switch self {
        case .adminRequired: "admin_required"
        case .funnelRefused: "funnel_refused"
        case .tailnetIdentityRequired: "tailnet_identity_required"
        case .scope: "scope"
        case .vehicleRequired: "vehicle_required"
        case .assignmentRefused: "assignment_refused"
        case .noStorageKey: "no_storage_key"
        case .enrolmentRefused: "enrolment_refused"
        case .other(let code): code
        }
    }
}

/// Everything a `CairnServerClient` call can refuse with. Error values carry no tokens,
/// signatures, bodies, cursors or URLs, so any of them is safe to log.
public enum CairnServerError: Error, Sendable, Equatable {
    /// 401 `unauthenticated`. Deliberately uniform: unknown client, bad signature, replay, stale
    /// clock and revocation all look the same, so the client does not guess which it was.
    case unauthenticated
    /// 401 `signature_required`: a bearer token went to a route that takes signatures only.
    case signatureRequired
    /// 401 `bad_manifest_signature` on the relay: the dongle's manifest is wrong, not the caller.
    /// Not a revocation, not a clock problem, and retrying the same bundle will not help.
    case badManifestSignature
    /// Repeated 401s, and `GET /v1/health` shows the phone's clock is outside the server's
    /// +/-120 s window. Positive: the phone is ahead of the server.
    case clockSkew(phoneAheadBySeconds: Int)
    case forbidden(ForbiddenReason)
    /// 410 `cursor_reset` outside `pull` (which reports it as `PullOutcome.cursorReset`).
    case cursorReset
    /// 429. `retryAfter` is the server's `Retry-After` in seconds, when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case badRequest(code: String)
    case notFound(code: String)
    case conflict(code: String)
    /// 422 `quarantined`: the bundle's counter was reused with different content.
    case quarantined
    /// 5xx: retry with backoff (spec section 4.3).
    case serverFailure(status: Int)
    /// A status or error code this client does not know. Not retryable unchanged.
    case unexpected(status: Int, code: String?)
    /// A 2xx whose body does not decode.
    case malformedResponse
    case transport(TransportFailure)
    /// The signer failed (key unavailable, Secure Enclave refused).
    case signingFailed
    /// A caller-supplied value would corrupt the request target (a path segment that is not hex).
    case invalidArgument(String)

    /// The HTTP status the server answered with, when it answered.
    public var httpStatus: Int? {
        switch self {
        case .unauthenticated, .signatureRequired, .badManifestSignature, .clockSkew: 401
        case .forbidden: 403
        case .cursorReset: 410
        case .rateLimited: 429
        case .badRequest: 400
        case .notFound: 404
        case .conflict: 409
        case .quarantined: 422
        case .serverFailure(let status): status
        case .unexpected(let status, _): status
        case .malformedResponse, .transport, .signingFailed, .invalidArgument: nil
        }
    }

    /// The `error` code in the server's body, when it sent one.
    public var errorCode: String? {
        switch self {
        case .unauthenticated, .clockSkew: "unauthenticated"
        case .signatureRequired: "signature_required"
        case .badManifestSignature: "bad_manifest_signature"
        case .forbidden(let reason): reason.code
        case .cursorReset: "cursor_reset"
        case .rateLimited: "rate_limited"
        case .badRequest(let code), .notFound(let code), .conflict(let code): code
        case .quarantined: "quarantined"
        case .unexpected(_, let code): code
        case .serverFailure, .malformedResponse, .transport, .signingFailed, .invalidArgument: nil
        }
    }
}
