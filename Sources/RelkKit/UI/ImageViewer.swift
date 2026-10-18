import SwiftUI
import UIKit

struct ImageViewerSelection: Identifiable {
    let id = UUID()
    let images: [ChatImage]
    let index: Int
}

/// Full-screen pager over one message's images: pinch or double-tap to zoom,
/// pull down to dismiss.
struct ImageViewer: View {
    let selection: ImageViewerSelection

    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(selection: ImageViewerSelection) {
        self.selection = selection
        _index = State(initialValue: selection.index)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(selection.images.enumerated()), id: \.element.id) { offset, image in
                    ZoomablePage(image: image, onDismiss: { dismiss() })
                        .tag(offset)
                        .accessibilityLabel(
                            Text("Screenshot \(offset + 1) of \(selection.images.count)", bundle: .module)
                        )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: selection.images.count > 1 ? .always : .never))
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .padding()
            .accessibilityLabel(Text("Close", bundle: .module))
        }
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
    }
}

private struct ZoomablePage: View {
    let image: ChatImage
    let onDismiss: () -> Void

    @Environment(\.relkImageLoader) private var loader
    @State private var uiImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let uiImage {
                ZoomableImageView(image: uiImage, onDismiss: onDismiss)
            } else if didFail {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: image.id) {
            uiImage = await image.load(maxPixelSize: ChatImage.fullPixelSize, loader: loader)
            didFail = uiImage == nil && !Task.isCancelled
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.image = image
        view.onDismiss = onDismiss
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onDismiss = onDismiss
        if view.image !== image { view.image = image }
    }
}

private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    var onDismiss: () -> Void = {}

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            setZoomScale(minimumZoomScale, animated: false)
            fittedForSize = nil
            setNeedsLayout()
        }
    }

    private let imageView = UIImageView()
    private var fittedForSize: CGSize?
    private static let dismissDistance: CGFloat = 100

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // Lets an unzoomed image be pulled down to dismiss.
        alwaysBounceVertical = true
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fittedForSize != bounds.size, zoomScale == minimumZoomScale, let image = imageView.image,
           image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            fittedForSize = bounds.size
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard zoomScale == minimumZoomScale else { return }
        let pulled = -(contentOffset.y + contentInset.top)
        if pulled > Self.dismissDistance { onDismiss() }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }
}
