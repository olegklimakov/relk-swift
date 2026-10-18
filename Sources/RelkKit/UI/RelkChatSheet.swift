import SwiftUI

extension View {
    /// Presents `RelkChatView` as a page sheet while `isPresented` is true,
    /// and also opens it when the user taps a Relk push (see `Relk.handle`).
    /// Apply it once, at the app root. The chat is presented from whatever is on
    /// top at that moment, so it also appears over the host's own sheets and covers.
    ///
    /// - Parameters:
    ///   - tint: colours the chat. A sheet does not inherit the presenter's
    ///     `.tint`, so without it the chat falls back to the AccentColor asset.
    ///   - presentsPushes: while `false`, a tapped push waits and opens the chat
    ///     as soon as it turns `true`; pass `false` while a splash or onboarding
    ///     screen is up.
    public func relkChat(
        isPresented: Binding<Bool>,
        screen: String? = nil,
        tint: Color? = nil,
        presentsPushes: Bool = true
    ) -> some View {
        modifier(RelkChatSheet(
            isPresented: isPresented, screen: screen, tint: tint, presentsPushes: presentsPushes
        ))
    }
}

private struct RelkChatSheet: ViewModifier {
    @Binding var isPresented: Bool
    let screen: String?
    let tint: Color?
    let presentsPushes: Bool

    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let runtime = RelkRuntime.shared
        content
            .onChange(of: isPresented, initial: true) { _, shown in
                if shown {
                    ChatPresenter.shared.present(owner: owner, screen: screen, tint: tint) { isPresented = false }
                } else {
                    ChatPresenter.shared.dismiss(owner: owner)
                }
            }
            // `initial` covers a cold launch from a push, where the request
            // lands before this view exists.
            .onChange(of: runtime.isPresentationRequested && presentsPushes, initial: true) { _, ready in
                guard ready else { return }
                runtime.isPresentationRequested = false
                isPresented = true
            }
    }
}
