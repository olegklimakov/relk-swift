import Foundation
import UIKit

/// A screenshot picked for the next message, already re-encoded for upload.
struct DraftImage: Identifiable, Sendable, Equatable {
    let id: UUID
    let encoded: EncodedImage
    let thumbnail: UIImage

    static func == (lhs: DraftImage, rhs: DraftImage) -> Bool {
        lhs.id == rhs.id
    }

    /// Runs ImageIO work; call off the main actor.
    static func make(from data: Data) throws -> DraftImage {
        let encoded = try ImageEncoder.encodeForUpload(data)
        guard let thumbnail = ImageEncoder.decode(encoded.jpeg, maxPixelSize: ChatImage.thumbnailPixelSize) else {
            throw RelkError.imageUnreadable
        }
        return DraftImage(id: UUID(), encoded: encoded, thumbnail: thumbnail)
    }
}

enum ChatImage: Identifiable, Equatable {
    case remote(MessageAttachment)
    case local(DraftImage)

    /// The 200 pt single-image bubble at 3x, with room for its 320 pt max height crop.
    static let thumbnailPixelSize = 720

    /// Every upload is re-encoded to at most this, so the viewer never needs more.
    static let fullPixelSize = ImageEncoder.maxPixelSize

    var id: UUID {
        switch self {
        case .remote(let attachment): attachment.id
        case .local(let draft): draft.id
        }
    }

    var aspectRatio: CGFloat {
        let (width, height) = switch self {
        case .remote(let attachment): (attachment.width, attachment.height)
        case .local(let draft): (draft.encoded.width, draft.encoded.height)
        }
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// What the chat renders: a server message, or a local one still sending or failed.
struct ChatMessage: Identifiable, Equatable {
    enum Status: Equatable {
        case sent
        case sending(progress: Double?)
        case failed
    }

    /// The `client_id` for the user's own messages, so a row keeps its
    /// identity when it turns from pending into sent.
    let id: UUID
    let sender: Message.Sender
    let body: String?
    let images: [ChatImage]
    let date: Date
    let status: Status
}

/// A message the user sent that the server hasn't confirmed yet.
struct Outgoing: Equatable {
    let clientId: UUID
    let body: String?
    let context: MessageContext
    let createdAt: Date
    let images: [DraftImage]
    var uploaded: [UUID: MessageAttachment] = [:]
    var uploadProgress: [UUID: Double] = [:]
    var isFailed = false

    mutating func discardUploads() {
        uploaded = [:]
        uploadProgress = [:]
    }

    var progress: Double? {
        guard !images.isEmpty else { return nil }
        let total = images.reduce(0) { $0 + $1.encoded.jpeg.count }
        guard total > 0 else { return nil }
        let done = images.reduce(0.0) { sum, image in
            let fraction = uploaded[image.id] != nil ? 1 : uploadProgress[image.id] ?? 0
            return sum + fraction * Double(image.encoded.jpeg.count)
        }
        return done / Double(total)
    }
}

extension ChatMessage {
    init(_ message: Message) {
        self.init(
            id: message.clientId ?? message.id,
            sender: message.sender,
            body: message.body,
            images: message.attachments.map(ChatImage.remote),
            date: message.createdAt,
            status: .sent
        )
    }

    init(_ outgoing: Outgoing) {
        self.init(
            id: outgoing.clientId,
            sender: .user,
            body: outgoing.body,
            images: outgoing.images.map(ChatImage.local),
            date: outgoing.createdAt,
            status: outgoing.isFailed ? .failed : .sending(progress: outgoing.progress)
        )
    }
}
