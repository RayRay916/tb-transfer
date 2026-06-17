import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Drag payload identifying a remote file or directory on a specific peer.
///
/// Used as the `Transferable` for `.draggable { ... }` on `RemoteFileBrowser` rows
/// so that drop targets (e.g. the local browser or the transfer panel) can decode
/// a `RemoteFileDragPayload` (or `[RemoteFileDragPayload]`) without going through
/// the file-URL pasteboard plumbing.
///
/// We declare a custom exported UTI (`com.tbtransfer.remote-file`) conforming to
/// `.data` so the payload is decoded as a `CodableRepresentation` blob.
struct RemoteFileDragPayload: Codable, Hashable, Sendable, Transferable {
    /// Identity of the peer the file lives on.
    let peerID: UUID

    /// Absolute remote path (e.g. `/Users/alice/file.dat`).
    let path: String

    /// True when the entry is a directory; false for files or symlinks.
    let isDirectory: Bool

    /// Last path component used purely for UI display while dragging.
    let displayName: String

    static let contentType = UTType(exportedAs: "com.tbtransfer.remote-file", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

/// A `Transferable` batch of `RemoteFileDragPayload` so multi-selected remote rows
/// can be dragged as a single transferable item. Uses a separate exported UTI so
/// drop targets can disambiguate the multi-item case.
struct RemoteFileDragBatch: Codable, Hashable, Sendable, Transferable {
    let items: [RemoteFileDragPayload]

    static let contentType = UTType(exportedAs: "com.tbtransfer.remote-file-batch", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
