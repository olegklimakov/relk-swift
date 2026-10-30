import SwiftUI

/// The developer's greeting at the top of the chat. The SDK draws it on the device: it is
/// never sent, never stored, and never reaches the inbox or Telegram.
///
/// ```swift
/// Relk.configure(
///     appKey: "rk_pub_…",
///     welcome: RelkWelcome("feedback.welcome", name: "Oleg", avatar: Image("developer"))
/// )
/// ```
/// The text comes from the host app's String Catalog, so it is translated with the app. A
/// literal resolves in the main bundle; strings kept in a package need its `bundle:`.
public struct RelkWelcome: Sendable {
    /// The greeting. A string literal is looked up in the main bundle's String Catalog.
    public var text: LocalizedStringResource
    /// Shown above the bubble and read first by VoiceOver; without it VoiceOver says "Developer".
    public var name: String?
    /// Cropped to fill a 32 pt circle beside the bubble; hidden from VoiceOver.
    public var avatar: Image?

    /// - Parameters:
    ///   - text: A key or literal from the host app's String Catalog.
    ///   - name: The developer's name above the bubble.
    ///   - avatar: A photo, cropped to a 32 pt circle.
    public init(_ text: LocalizedStringResource, name: String? = nil, avatar: Image? = nil) {
        self.text = text
        self.name = name
        self.avatar = avatar
    }
}

struct WelcomeRow: View {
    let welcome: RelkWelcome

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let avatar = welcome.avatar {
                avatar
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(.circle)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let name = welcome.name {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
                Text(welcome.text)
                    .foregroundStyle(.primary)
                    .chatBubble(isOwn: false)
            }
            Spacer(minLength: 56)
        }
        .padding(.bottom, 12)
        // Read like a developer's message: sender first.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(welcome.name.map { Text($0) } ?? Text("Developer", bundle: .module)), \(Text(welcome.text))")
        )
    }
}
