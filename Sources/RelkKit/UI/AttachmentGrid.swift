import SwiftUI

struct AttachmentGrid: View {
    let images: [ChatImage]
    let onOpen: (Int) -> Void

    private static let singleWidth: CGFloat = 200
    private static let singleMaxHeight: CGFloat = 320
    private static let tileSide: CGFloat = 116
    private static let spacing: CGFloat = 2

    var body: some View {
        Group {
            if images.count == 1 {
                tile(0)
                    .frame(width: Self.singleWidth, height: singleHeight)
            } else {
                Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                    ForEach(Array(stride(from: 0, to: images.count, by: 2)), id: \.self) { row in
                        GridRow {
                            tile(row).frame(width: Self.tileSide, height: Self.tileSide)
                            if row + 1 < images.count {
                                tile(row + 1).frame(width: Self.tileSide, height: Self.tileSide)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var singleHeight: CGFloat {
        min(Self.singleMaxHeight, Self.singleWidth / max(images[0].aspectRatio, 0.3))
    }

    private func tile(_ index: Int) -> some View {
        Button {
            onOpen(index)
        } label: {
            ChatImageView(image: images[index], maxPixelSize: ChatImage.thumbnailPixelSize, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Screenshot \(index + 1) of \(images.count)", bundle: .module))
    }
}

struct ChatImageView: View {
    let image: ChatImage
    let maxPixelSize: Int
    var contentMode: ContentMode = .fill

    @Environment(\.relkImageLoader) private var loader
    @State private var phase = Phase.loading

    private enum Phase {
        case loading
        case loaded(UIImage)
        case failed
    }

    var body: some View {
        ZStack {
            switch phase {
            case .loaded(let uiImage):
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .loading:
                Rectangle().fill(.quaternary)
                ProgressView()
            case .failed:
                Rectangle().fill(.quaternary)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: TaskKey(image: image.id, maxPixelSize: maxPixelSize)) {
            await load()
        }
    }

    private struct TaskKey: Equatable {
        let image: UUID
        let maxPixelSize: Int
    }

    private func load() async {
        if let uiImage = await image.load(maxPixelSize: maxPixelSize, loader: loader) {
            phase = .loaded(uiImage)
        } else if !Task.isCancelled {
            phase = .failed
        }
    }
}

extension ChatImage {
    /// `nil` when the image can't be fetched or decoded.
    func load(maxPixelSize: Int, loader: ImageLoader?) async -> UIImage? {
        switch self {
        case .local(let draft):
            if maxPixelSize == ChatImage.thumbnailPixelSize { return draft.thumbnail }
            let jpeg = draft.encoded.jpeg
            return await Task.detached(priority: .userInitiated) {
                ImageEncoder.decode(jpeg, maxPixelSize: maxPixelSize)
            }.value
        case .remote(let attachment):
            return try? await loader?.image(path: attachment.url, maxPixelSize: maxPixelSize)
        }
    }
}
