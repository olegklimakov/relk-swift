import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onOpenImage: (Int) -> Void

    var body: some View {
        switch message.sender {
        case .system:
            if let body = message.body {
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
            }
        case .user, .developer:
            bubbleRow
        }
    }

    private var isOwn: Bool { message.sender == .user }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isOwn { Spacer(minLength: 56) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                if !message.images.isEmpty {
                    AttachmentGrid(images: message.images, onOpen: onOpenImage)
                }
                if let body = message.body {
                    textBubble(body)
                }
                statusLine
            }
            .opacity(isSending ? 0.6 : 1)
            if !isOwn { Spacer(minLength: 56) }
        }
    }

    private func textBubble(_ body: String) -> some View {
        Text(ChatFormatting.linkified(body))
            .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .tint(isOwn ? .white : nil)
            .chatBubble(isOwn: isOwn)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contextMenu {
                if isFailed { failedActions }
                Button {
                    UIPasteboard.general.string = body
                } label: {
                    Label { Text("Copy", bundle: .module) } icon: { Image(systemName: "doc.on.doc") }
                }
            }
            // Enabled only when failed, so it never competes with link taps.
            .gesture(TapGesture().onEnded(onRetry), including: isFailed ? .all : .subviews)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(senderLabel + Text(verbatim: ", ") + Text(body))
            .accessibilityAddTraits(isFailed ? .isButton : [])
            .accessibilityHint(isFailed ? Text("Double-tap to retry.", bundle: .module) : Text(verbatim: ""))
            .accessibilityActions {
                if isFailed { failedActions }
            }
    }

    @ViewBuilder
    private var failedActions: some View {
        Button(action: onRetry) {
            Label { Text("Retry", bundle: .module) } icon: { Image(systemName: "arrow.clockwise") }
        }
        Button(role: .destructive, action: onDiscard) {
            Label { Text("Delete", bundle: .module) } icon: { Image(systemName: "trash") }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch message.status {
        case .sent:
            EmptyView()
        case .sending(let progress):
            HStack(spacing: 6) {
                if let progress, progress < 1 {
                    ProgressView(value: progress)
                        .frame(width: 60)
                }
                Text("Sending…", bundle: .module)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .failed:
            Button(action: onRetry) {
                Label {
                    Text("Not delivered. Tap to retry.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            // The only place to delete an image-only message, which has no text bubble.
            .contextMenu { failedActions }
            .accessibilityActions { failedActions }
        }
    }

    private var isFailed: Bool { message.status == .failed }

    private var isSending: Bool {
        if case .sending = message.status { return true }
        return false
    }

    private var senderLabel: Text {
        switch message.sender {
        case .user: Text("You", bundle: .module)
        case .developer, .system: Text("Developer", bundle: .module)
        }
    }
}

extension View {
    /// The bubble of every text message, and of the welcome, which must read as the
    /// developer's (D53).
    func chatBubble(isOwn: Bool) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isOwn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}
