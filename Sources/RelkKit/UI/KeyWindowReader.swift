import SwiftUI
import UIKit

/// Reports whether the window this view was last placed in is key. A host's lock
/// cover takes key while it is up, so the chat under it can tell it is not seen.
struct KeyWindowReader: UIViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeUIView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: @MainActor (Bool) -> Void
        /// Kept while the view is out of the window: the image viewer's full-screen
        /// cover takes the chat out of it without the chat leaving the screen.
        private(set) weak var observedWindow: UIWindow?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== observedWindow else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            center.addObserver(self, selector: #selector(report), name: UIWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(report), name: UIWindow.didResignKeyNotification, object: window)
            observedWindow = window
            report()
        }

        @objc private func report() {
            onChange(observedWindow?.isKeyWindow ?? false)
        }
    }
}
