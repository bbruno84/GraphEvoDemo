import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Decode a thumbnail directly from the provider's scoped file, never full original Data.
enum NotesCoverLoader {
    static func thumbnail(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    static func load(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url else { continuation.resume(throwing: error ?? NotesError.invalidRecord); return }
                do {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                             kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw NotesError.invalidRecord }
                    for quality in [0.82, 0.65, 0.45] {
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NotesError.invalidRecord }
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else { throw NotesError.invalidRecord }
                        if data.length <= 2 * 1024 * 1024 { continuation.resume(returning: data as Data); return }
                    }
                    throw NotesError.invalidRecord
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
