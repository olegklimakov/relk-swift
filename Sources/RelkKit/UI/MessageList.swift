import SwiftUI

struct MessageList: View {
    let messages: [ChatMessage]
    var welcome: RelkWelcome?
    var isLoadingHistory = false
    let onRetry: (UUID) -> Void
    let onDiscard: (UUID) -> Void
    let onOpenImage: ([ChatImage], Int) -> Void
    let showsNotificationPrompt: Bool
    let onEnableNotifications: () -> Void

    private static let notificationPromptID = UUID()

    /// The row at the bottom edge; `nil` until the user scrolls.
    @State private var bottomRowID: UUID?

    /// A pause longer than this starts a new timestamped group.
    private static let groupGap: TimeInterval = 60 * 60

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let welcome {
                        WelcomeRow(welcome: welcome)
                    }
                    if isLoadingHistory {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        VStack(spacing: 0) {
                            if startsGroup(at: index) {
                                TimestampHeader(date: message.date)
                            }
                            MessageRow(
                                message: message,
                                onRetry: { onRetry(message.id) },
                                onDiscard: { onDiscard(message.id) },
                                onOpenImage: { onOpenImage(message.images, $0) }
                            )
                            .padding(.top, spacing(before: index))
                        }
                    }
                    if showsNotificationPrompt {
                        NotificationPromptRow(onEnable: onEnableNotifications)
                            .id(Self.notificationPromptID)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollPosition(id: $bottomRowID, anchor: .bottom)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { previous, _ in
                followBottom(proxy, previousLastID: previous)
            }
            .onChange(of: showsNotificationPrompt) {
                followBottom(proxy, previousLastID: messages.last?.id)
            }
        }
    }

    /// Someone reading older history isn't yanked down by a reply; their own
    /// message always brings them back.
    private func followBottom(_ proxy: ScrollViewProxy, previousLastID: UUID?) {
        let wasAtBottom = bottomRowID == nil
            || bottomRowID == previousLastID
            || bottomRowID == Self.notificationPromptID
        guard wasAtBottom || messages.last?.sender == .user else { return }
        guard let target = showsNotificationPrompt ? Self.notificationPromptID : messages.last?.id else { return }
        // The history arriving under a welcome jumps to its end; animating through a lazy
        // list of estimated row heights can stop short.
        guard previousLastID != nil else {
            proxy.scrollTo(target, anchor: .bottom)
            return
        }
        withAnimation(.snappy) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = messages[index - 1].date
        let current = messages[index].date
        return current.timeIntervalSince(previous) > Self.groupGap
            || !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0, !startsGroup(at: index) else { return 0 }
        return messages[index - 1].sender == messages[index].sender ? 2 : 10
    }
}

private struct TimestampHeader: View {
    let date: Date

    var body: some View {
        Text(ChatFormatting.timestamp(date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
enum ChatFormatting {
    /// "Today at 14:05", "Yesterday at 09:12", "12 Sep 2026 at 10:00", localized.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Rows re-render on every store change (upload progress included);
    /// detection runs once per text instead.
    private static var linkified: [String: AttributedString] = [:]

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    static func linkified(_ text: String) -> AttributedString {
        if let cached = linkified[text] { return cached }
        let result = detectLinks(in: text)
        linkified[text] = result
        return result
    }

    private static func detectLinks(in text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let linkDetector else { return result }
        let matches = linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let attributedRange = Range(range, in: result)
            else { continue }
            result[attributedRange].link = url
            result[attributedRange].underlineStyle = .single
        }
        return result
    }
}

private struct NotificationPromptRow: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("Get notified when the developer replies", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onEnable) {
                Text("Turn On", bundle: .module)
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Get notified when the developer replies", bundle: .module))
        .accessibilityHint(Text("Double-tap to turn on notifications.", bundle: .module))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onEnable() }
    }
}
