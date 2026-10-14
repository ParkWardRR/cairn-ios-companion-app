import Foundation

// Wire models for sync/v1 (contracts/sync/v1/spec.md). Timestamps stay the strings the server
// sent, and opaque values (cursor, epoch, token) stay strings nobody parses; the typed accessors
// are conveniences. Unknown fields are ignored, so an additive server change does not break us.

public struct ServerBuild: Codable, Sendable, Equatable {
    public var version: String
    public var commit: String
    public var modified: Bool?
}

/// `GET /v1/health` (section 8).
public struct HealthInfo: Codable, Sendable, Equatable {
    public var status: String
    public var protocolVersion: Int
    public var instanceID: String
    public var serverTime: String
    public var build: ServerBuild?

    enum CodingKeys: String, CodingKey {
        case status, build
        case protocolVersion = "protocol_version"
        case instanceID = "instance_id"
        case serverTime = "server_time"
    }

    public var serverDate: Date? { ServerTimestamp.parse(serverTime) }
}

public struct ServerIdentity: Codable, Sendable, Equatable {
    public var instanceID: String
    /// SHA-256 of the LAN leaf's SubjectPublicKeyInfo, hex. Empty on plain HTTP behind Tailscale Serve.
    public var spkiSHA256: String

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case spkiSHA256 = "spki_sha256"
    }
}

/// `201` from `POST /v1/enroll/app` (section 3).
public struct EnrolmentResult: Codable, Sendable, Equatable {
    public var clientID: String
    public var role: String
    /// Vehicle ids this client may touch; `["*"]` is every vehicle.
    public var vehicles: [String]
    public var serverTime: String
    public var serverIdentity: ServerIdentity

    enum CodingKeys: String, CodingKey {
        case role, vehicles
        case clientID = "client_id"
        case serverTime = "server_time"
        case serverIdentity = "server_identity"
    }
}

/// `POST /v1/auth/token` (section 2.3). The token is opaque.
public struct TokenGrant: Codable, Sendable, Equatable {
    public var token: String
    public var expiresAt: String
    public var scope: String

    enum CodingKeys: String, CodingKey {
        case token, scope
        case expiresAt = "expires_at"
    }
}

extension TokenGrant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "TokenGrant(scope: \(scope))" }
    public var debugDescription: String { description }
}

/// One operation of a push (section 4). `payload` and `contentHash` are the caller's: the hash
/// is over the canonical form of the payload (section 4.1).
public struct SyncOperation: Codable, Sendable, Equatable {
    public var operationID: String
    public var clientID: String
    public var vehicleID: String
    public var kind: String
    public var createdAt: String
    public var payloadVersion: Int
    public var payload: JSONValue
    public var contentHash: String
    public var idempotencyKey: String?
    /// Mutable kinds only: the revision of each field you last saw.
    public var baseRevision: [String: Int]?

    public init(
        operationID: String, clientID: String, vehicleID: String, kind: String, createdAt: String,
        payloadVersion: Int = 1, payload: JSONValue, contentHash: String,
        idempotencyKey: String? = nil, baseRevision: [String: Int]? = nil
    ) {
        self.operationID = operationID
        self.clientID = clientID
        self.vehicleID = vehicleID
        self.kind = kind
        self.createdAt = createdAt
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.contentHash = contentHash
        self.idempotencyKey = idempotencyKey
        self.baseRevision = baseRevision
    }

    enum CodingKeys: String, CodingKey {
        case kind, payload
        case operationID = "operation_id"
        case clientID = "client_id"
        case vehicleID = "vehicle_id"
        case createdAt = "created_at"
        case payloadVersion = "payload_version"
        case contentHash = "content_hash"
        case idempotencyKey = "idempotency_key"
        case baseRevision = "base_revision"
    }
}

/// What the server did with one operation (section 4.3).
public enum PushStatus: Sendable, Equatable, Codable {
    case accepted
    case duplicate
    case conflict
    case rejected
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "accepted": self = .accepted
        case "duplicate": self = .duplicate
        case "conflict": self = .conflict
        case "rejected": self = .rejected
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .accepted: try container.encode("accepted")
        case .duplicate: try container.encode("duplicate")
        case .conflict: try container.encode("conflict")
        case .rejected: try container.encode("rejected")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

public struct FieldConflict: Codable, Sendable, Equatable {
    public var field: String
    public var currentRevision: Int
    public var currentValue: JSONValue

    enum CodingKeys: String, CodingKey {
        case field
        case currentRevision = "current_revision"
        case currentValue = "current_value"
    }
}

public struct PushResult: Codable, Sendable, Equatable {
    public var operationID: String
    public var status: PushStatus
    public var serverSequence: Int64?
    public var revisions: [String: Int]?
    /// On `duplicate`: what the first sighting was.
    public var originalStatus: String?
    public var conflicts: [FieldConflict]?
    /// On `rejected`: permanent for this operation (section 4.3 lists the reasons).
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case status, revisions, conflicts, reason
        case operationID = "operation_id"
        case serverSequence = "server_sequence"
        case originalStatus = "original_status"
    }
}

public struct PushResponse: Codable, Sendable, Equatable {
    public var results: [PushResult]
    public var head: Int64
}

/// One entry of a pull page (section 5): an `entity` (vehicle, assignment, trip_summary) or an
/// `operation`. Only the fields that kind carries are set.
public struct SyncChange: Codable, Sendable, Equatable {
    public var serverSequence: Int64
    public var at: Int64
    public var type: String
    public var entityType: String?
    public var entityID: String?
    public var vehicleID: String?
    public var data: JSONValue?
    public var operation: JSONValue?
    public var deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case at, type, data, operation, deleted
        case serverSequence = "server_sequence"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case vehicleID = "vehicle_id"
    }
}

public struct PullPage: Codable, Sendable, Equatable {
    public var epoch: String
    /// Opaque, durable and repeatable. Never built or parsed here; persist it with the page.
    public var cursor: String
    public var hasMore: Bool
    public var changes: [SyncChange]

    enum CodingKeys: String, CodingKey {
        case epoch, cursor, changes
        case hasMore = "has_more"
    }
}

/// The result of a pull. A reset is its own case, so it cannot be mistaken for "no changes":
/// on `cursorReset` discard the server-derived data, keep the unsent outbox, pull from scratch.
public enum PullOutcome: Sendable, Equatable {
    case page(PullPage)
    case cursorReset
}

public struct AckResponse: Codable, Sendable, Equatable {
    public var acknowledged: Int64
}

/// A chunk the server still wants, with where it lives in the bundle byte stream (section 13).
public struct MissingChunk: Codable, Sendable, Equatable {
    public var index: Int
    public var offset: Int64
    public var length: Int64
    public var sha256: String
}

public struct RelayOffer: Codable, Sendable, Equatable {
    public var bundleID: String
    public var missingChunks: [MissingChunk]
    public var receiptAvailable: Bool
    public var totalChunks: Int?
    public var bytesExpected: Int64?
    public var bytesOutstanding: Int64?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case missingChunks = "missing_chunks"
        case receiptAvailable = "receipt_available"
        case totalChunks = "total_chunks"
        case bytesExpected = "bytes_expected"
        case bytesOutstanding = "bytes_outstanding"
    }
}

public struct ChunkAck: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// Indices still missing after this chunk.
    public var missingChunks: [Int]

    enum CodingKeys: String, CodingKey {
        case accepted
        case missingChunks = "missing_chunks"
    }
}

/// The signed receipt, CBOR, exactly as the server sent it: its signature covers these bytes,
/// so they are kept and stored verbatim (section 13).
public struct RelayReceipt: Sendable, Equatable {
    public var bytes: Data
    public var receiptID: String?
    /// `X-Cairn-Already-Committed` was set: the bundle was committed before this call.
    public var alreadyCommitted: Bool

    public init(bytes: Data, receiptID: String?, alreadyCommitted: Bool) {
        self.bytes = bytes
        self.receiptID = receiptID
        self.alreadyCommitted = alreadyCommitted
    }
}

// MARK: - Admin

public struct ClientEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { clientID }
    public var clientID: String
    public var name: String?
    public var role: String
    public var status: String
    public var vehicles: [String]?
    public var lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case name, role, status, vehicles
        case lastSeenAt = "last_seen_at"
    }

    public var isRevoked: Bool { status == "revoked" }
}

public struct DeviceEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { deviceID }
    public var deviceID: String
    public var status: String
    public var lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case status
        case lastSeenAt = "last_seen_at"
    }

    public var isRevoked: Bool { status == "revoked" }
}

enum ServerTimestamp {
    /// RFC 3339, with or without fractional seconds.
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
