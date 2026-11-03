import Combine
import SwiftUI

/// The feedback chat. Present it as a sheet (or use `.relkChat`); it
/// brings its own navigation bar.
public struct RelkChatView: View {
    private let screen: String?
    private let meta: [String: RelkMetaValue]
    private let onDone: (@MainActor () -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    /// - Parameters:
    ///   - screen: where the chat was opened from; sent with every message so the
    ///     developer sees the context.
    ///   - meta: your app's own JSON, attached to every message sent while the chat
    ///     shows it; see `relkChat(isPresented:screen:meta:tint:presentsPushes:)`.
    public init(screen: String? = nil, meta: [String: RelkMetaValue] = [:]) {
        self.init(screen: screen, meta: meta, onDone: nil)
    }

    /// `onDone` replaces `dismiss`, which can't reach a UIKit presentation.
    init(screen: String?, meta: [String: RelkMetaValue], onDone: (@MainActor () -> Void)?) {
        self.screen = screen
        self.meta = meta
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let session = RelkRuntime.shared.session {
                    ChatScreen(store: session.chat, screen: screen, meta: meta, welcome: RelkRuntime.shared.welcome)
                        .environment(\.relkImageLoader, session.images)
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("Relk isn't configured", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.bubble")
                        }
                    } description: {
                        Text("Call Relk.configure(appKey:) at launch.", bundle: .module)
                    }
                }
            }
            .navigationTitle(Text("Feedback", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPresented || onDone != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if let onDone { onDone() } else { dismiss() }
                        } label: {
                            Text("Done", bundle: .module)
                        }
                    }
                }
            }
        }
    }
}

struct ChatScreen: View {
    @Bindable var store: ChatStore
    let screen: String?
    let meta: [String: RelkMetaValue]
    var welcome: RelkWelcome?

    /// From UIApplication, not `scenePhase`: a UIHostingController presented
    /// through UIKit (as `.relkChat` does) never receives the scene's phase.
    @State private var isAppActive = UIApplication.shared.applicationState == .active
    @State private var isOnScreen = false
    @State private var isWindowKey = false
    @State private var viewer: ImageViewerSelection?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(store: store, screen: screen, meta: meta)
            }
            .onAppear {
                isOnScreen = true
                updateLive()
            }
            // Activations are refreshed by the runtime's observer.
            .task {
                await store.refreshNotificationStatus()
            }
            .onDisappear {
                isOnScreen = false
                updateLive()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                isAppActive = true
                updateLive()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                isAppActive = false
                updateLive()
            }
            .onChange(of: viewer == nil) {
                updateLive()
            }
            .background {
                KeyWindowReader { isKey in
                    isWindowKey = isKey
                    updateLive()
                }
            }
            .fullScreenCover(item: $viewer) { selection in
                ImageViewer(selection: selection)
            }
    }

    @ViewBuilder
    private var content: some View {
        let messages = store.messages
        switch ChatContent.resolve(isEmpty: messages.isEmpty, loadState: store.loadState, hasWelcome: welcome != nil) {
        case .failed(let error):
            LoadErrorView(error: error) {
                Task { await store.sync() }
            }
        case .loading:
            ProgressView()
        case .empty:
            EmptyChatView()
        case .list(let loadingHistory):
            MessageList(
                messages: messages,
                welcome: welcome,
                isLoadingHistory: loadingHistory,
                onRetry: { store.retry($0) },
                onDiscard: { store.discard($0) },
                onOpenImage: { images, index in
                    viewer = ImageViewerSelection(images: images, index: index)
                },
                showsNotificationPrompt: store.showsNotificationPrompt,
                onEnableNotifications: {
                    Task { await store.enableNotifications() }
                }
            )
        }
    }

    /// The image viewer's full-screen cover makes this view disappear; the
    /// chat stays live underneath it. Under a host's lock cover, which holds key,
    /// it is not: replies would be marked read and their banners dropped unseen.
    private func updateLive() {
        store.setLive((isOnScreen || viewer != nil) && isAppActive && isWindowKey)
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Write to the developer", bundle: .module)
                .font(.title3.weight(.semibold))
            Text("The developer reads every message personally. Replies show up right here.", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

private struct LoadErrorView: View {
    let error: RelkError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Couldn't load messages", bundle: .module)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
        } description: {
            if case .network = error {
                Text("Check your connection and try again.", bundle: .module)
            } else {
                Text("Something went wrong on our side. Please try again later.", bundle: .module)
            }
        } actions: {
            Button(action: retry) {
                Text("Try Again", bundle: .module)
            }
            .buttonStyle(.bordered)
        }
    }
}

extension EnvironmentValues {
    @Entry var relkImageLoader: ImageLoader?
}
