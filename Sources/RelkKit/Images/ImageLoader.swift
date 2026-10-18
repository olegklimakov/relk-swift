import Foundation
import UIKit

/// Loads attachment images through the authenticated API (`AsyncImage` can't
/// send a bearer header). Raw bytes and decoded images are kept in memory; the
/// session's URLCache holds the bytes on disk.
actor ImageLoader {
    private let fetch: @Sendable (String) async throws -> Data
    private let data = NSCache<NSString, NSData>()
    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<(Data, UIImage), any Error>] = [:]

    init(fetch: @escaping @Sendable (String) async throws -> Data) {
        self.fetch = fetch
        data.totalCostLimit = 32 * 1024 * 1024
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func image(path: String, maxPixelSize: Int) async throws -> UIImage {
        let key = "\(path)#\(maxPixelSize)"
        if let cached = images.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return try await task.value.1 }

        let cachedData = data.object(forKey: path as NSString) as Data?
        let fetch = fetch
        let task = Task.detached(priority: .userInitiated) { () throws -> (Data, UIImage) in
            let bytes: Data
            if let cachedData {
                bytes = cachedData
            } else {
                bytes = try await fetch(path)
            }
            guard let image = ImageEncoder.decode(bytes, maxPixelSize: maxPixelSize) else {
                throw RelkError.imageUnreadable
            }
            return (bytes, image)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let (bytes, image) = try await task.value
        data.setObject(bytes as NSData, forKey: path as NSString, cost: bytes.count)
        images.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        return image
    }

    /// Lets a just-uploaded attachment render from the local JPEG instead of
    /// being downloaded again.
    func seed(_ jpeg: Data, path: String) {
        data.setObject(jpeg as NSData, forKey: path as NSString, cost: jpeg.count)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
