import CairnProtocol
import CryptoKit
import Foundation

public protocol ChunkProvider: Sendable {
    func readChunk(offset: Int64, length: Int64) async throws -> Data
}

public actor BundleRelayService {
    private let client: CairnServerClient

    public init(client: CairnServerClient) {
        self.client = client
    }

    /// A chunk the dongle gave us does not hash to what the server's offer says it must.
    public struct ChunkDigestMismatch: Error, Equatable, Sendable {
        public var index: Int
        public var expected: String
        public var actual: String
    }

    public struct RelayResult: Sendable {
        public var bundleID: String
        public var receipt: RelayReceipt?
        public var chunksUploaded: Int
        public var alreadyCommitted: Bool
    }

    public func relay(
        manifest: Data,
        signature: String,
        chunkProvider: any ChunkProvider,
        useBearer: Bool = false,
        verifyChunkDigests: Bool = false,
        onChunk: (@Sendable (_ uploaded: Int, _ total: Int, _ bytes: Int64) -> Void)? = nil
    ) async throws -> RelayResult {
        let offer = try await client.relayOffer(manifest: manifest, signature: signature)

        if offer.receiptAvailable && offer.missingChunks.isEmpty {
            let receipt = try await client.relayReceipt(bundleID: offer.bundleID)
            return RelayResult(
                bundleID: offer.bundleID,
                receipt: receipt,
                chunksUploaded: 0,
                alreadyCommitted: true
            )
        }

        var uploaded = 0
        for (position, chunk) in offer.missingChunks.enumerated() {
            let data = try await chunkProvider.readChunk(offset: chunk.offset, length: chunk.length)
            if verifyChunkDigests {
                // The server checks this too; checking here avoids uploading a chunk already
                // known to be bad (offload.md section 4).
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == chunk.sha256.lowercased() else {
                    throw ChunkDigestMismatch(index: chunk.index, expected: chunk.sha256, actual: actual)
                }
            }
            _ = try await client.relayChunk(
                bundleID: offer.bundleID,
                sha256: chunk.sha256,
                data: data,
                useBearer: useBearer
            )
            uploaded += 1
            onChunk?(position + 1, offer.missingChunks.count, chunk.length)
        }

        let receipt = try await client.relayCommit(bundleID: offer.bundleID)
        return RelayResult(
            bundleID: offer.bundleID,
            receipt: receipt,
            chunksUploaded: uploaded,
            alreadyCommitted: receipt.alreadyCommitted
        )
    }

    public func fetchReceipt(bundleID: String) async throws -> RelayReceipt {
        try await client.relayReceipt(bundleID: bundleID)
    }
}
