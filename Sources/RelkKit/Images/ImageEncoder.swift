import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct EncodedImage: Sendable, Equatable {
    let jpeg: Data
    let width: Int
    let height: Int
}

enum ImageEncoder {
    static let maxPixelSize = 2048
    /// The server's upload limit.
    static let maxBytes = 5 * 1024 * 1024

    /// Downsamples to `maxPixelSize` and writes a fresh JPEG. Source
    /// properties are never copied, so EXIF, GPS and TIFF metadata are dropped.
    static func encodeForUpload(_ data: Data) throws -> EncodedImage {
        guard let image = downsample(data, maxPixelSize: maxPixelSize) else {
            throw RelkError.imageUnreadable
        }
        for quality in [0.8, 0.6, 0.4] {
            let jpeg = try encodeJPEG(image, quality: quality)
            if jpeg.count <= maxBytes {
                return EncodedImage(jpeg: jpeg, width: image.width, height: image.height)
            }
        }
        throw RelkError.imageTooLarge
    }

    /// Decodes at most `maxPixelSize` on the longest side, orientation applied.
    /// Decoding happens here rather than lazily at first draw on the main thread.
    static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        downsample(data, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw RelkError.imageUnreadable }
        let options = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Transparent PNG screenshots would otherwise turn black.
            kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1),
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw RelkError.imageUnreadable }
        return output as Data
    }
}
