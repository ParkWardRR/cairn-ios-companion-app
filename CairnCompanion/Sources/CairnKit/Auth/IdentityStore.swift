import CairnProtocol
import Foundation

public protocol IdentityStore: Sendable {
    func load() async -> (EnrolmentState, EnrolledIdentity?)
    func save(state: EnrolmentState, identity: EnrolledIdentity?) async throws
    func clear() async throws
}

public actor InMemoryIdentityStore: IdentityStore {
    private var state: EnrolmentState = .notEnrolled
    private var identity: EnrolledIdentity?

    public init() {}

    public init(state: EnrolmentState, identity: EnrolledIdentity? = nil) {
        self.state = state
        self.identity = identity
    }

    public func load() -> (EnrolmentState, EnrolledIdentity?) {
        (state, identity)
    }

    public func save(state: EnrolmentState, identity: EnrolledIdentity?) {
        self.state = state
        self.identity = identity
    }

    public func clear() {
        state = .notEnrolled
        identity = nil
    }
}
