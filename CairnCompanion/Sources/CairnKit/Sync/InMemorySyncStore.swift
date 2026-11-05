import Foundation

/// A `SyncStore` in memory, for tests and for a phone whose database would not open.
///
/// A phone that cannot open its database is not a phone with no app: the link, the priming and
/// the diagnostics all still work, and the trips simply do not survive a relaunch. Saying that
/// out loud by having a fallback beats a crash on launch.
public actor InMemorySyncStore: SyncStore {
    private var book: TripBook?
    private var cursor: SyncCursor?

    public init() {}

    public func loadCursor() -> SyncCursor? { cursor }
    public func loadBook() -> TripBook? { book }

    public func save(book: TripBook, cursor: SyncCursor) throws {
        self.book = book
        self.cursor = cursor
    }
}
