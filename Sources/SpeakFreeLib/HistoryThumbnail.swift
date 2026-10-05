// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-01
import AppKit
import ImageIO
import SwiftUI

/// Decode a small preview off-main from stored bytes only. Never open a copied
/// file URL, fetch a network URL, or rasterize the original image at full size.
struct HistoryThumbnail: View {
    let entry: HistoryEntry
    var sideLength: CGFloat = 42
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: entry.id) {
            let data = entry.items.lazy.flatMap(\.representations)
                .first { HistoryEntry.imageTypes.contains($0.type) }?.data
            guard let data else { return }
            let preview: NSImage? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let source = CGImageSourceCreateWithData(data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 100,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary) else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: NSImage(cgImage: thumbnail, size: .zero))
                }
            }
            if !Task.isCancelled { image = preview }
        }
    }
}
