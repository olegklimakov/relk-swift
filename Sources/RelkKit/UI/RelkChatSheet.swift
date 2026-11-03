import SwiftUI

extension View {
    /// Presents `RelkChatView` as a page sheet while `isPresented` is true,
    /// and also opens it when the user taps a Relk push (see `Relk.handle`).
    /// Apply it once, at the app root. The chat is presented from whatever is on
    /// top at that moment, so it also appears over the host's own sheets and covers.
    ///
    /// - Parameters:
    ///   - isPresented: set to `false` by the SDK when the user closes the chat, or when
    ///     it can't be presented (another `.relkChat` is already showing it).
    ///   - screen: where the chat was opened from; sent with every message so the
    ///     developer sees the context.
    ///   - meta: your app's own JSON, attached to every message sent while the chat is
    ///     open and shown to the developer in the dashboard as sent by the app. A chat
    ///     opened by a tapped push gets the meta of this modifier, so keep a root modifier's
    ///     meta empty, and pass `presentsPushes: false` on any other one that carries meta.
    ///     A change applies from the next message. Over the limits in
    ///     docs/api.md (4 KB, 3 levels, 64-character keys) it is dropped and the message
    ///     goes without it.
    ///   - tint: colours the chat. A sheet does not inherit the presenter's
    ///     `.tint`, so without it the chat falls back to the AccentColor asset.
    ///   - presentsPushes: while `false`, a tapped push waits and opens the chat
    ///     as soon as it turns `true`; pass `false` while a splash or onboarding
    ///     screen is up.
    public func relkChat(
        isPresented: Binding<Bool>,
        screen: String? = nil,
        meta: [String: RelkMetaValue] = [:],
        tint: Color? = nil,
        presentsPushes: Bool = true
    ) -> some View {
        modifier(RelkChatSheet(
            isPresented: isPresented, screen: screen, meta: meta, tint: tint, presentsPushes: presentsPushes
        ))
    }
}

private struct RelkChatSheet: ViewModifier {
    @Binding var isPresented: Bool
    let screen: String?
    let meta: [String: RelkMetaValue]
    let tint: Color?
    let presentsPushes: Bool

    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let runtime = RelkRuntime.shared
        content
            .onChange(of: isPresented, initial: true) { _, shown in
                if shown {
                    ChatPresenter.shared.present(owner: owner, screen: screen, meta: meta, tint: tint) {
                        isPresented = false
                    }
                } else {
                    ChatPresenter.shared.dismiss(owner: owner)
                }
            }
            .onChange(of: meta) { _, meta in
                ChatPresenter.shared.update(owner: owner, meta: meta)
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
