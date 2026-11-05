import Foundation

public struct Annotation: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var vehicleID: String?
    public var targetID: String
    public var kind: AnnotationKind
    public var updatedAt: Date
    public var revision: Int

    public var text: String
    public var tags: [String]

    public init(
        id: String = UUID().uuidString,
        vehicleID: String? = nil,
        targetID: String,
        kind: AnnotationKind = .note,
        updatedAt: Date = Date(),
        revision: Int = 1,
        text: String,
        tags: [String] = []
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.targetID = targetID
        self.kind = kind
        self.updatedAt = updatedAt
        self.revision = revision
        self.text = text
        self.tags = tags
    }
}

public enum AnnotationKind: String, Codable, Sendable, CaseIterable, Hashable {
    case note
    case flag
    case favorite

    public var displayName: String {
        switch self {
        case .note: "Note"
        case .flag: "Flag"
        case .favorite: "Favorite"
        }
    }

    public var systemImage: String {
        switch self {
        case .note: "note.text"
        case .flag: "flag.fill"
        case .favorite: "star.fill"
        }
    }
}
