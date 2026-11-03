/// Who asks the user for notification permission. iOS shows its dialog once per install,
/// so a host with its own soft ask keeps that dialog for its own moment.
///
/// Under every option the SDK calls `registerForRemoteNotifications()` at launch once
/// notifications are allowed, however they were granted.
public enum RelkNotificationPrompt: Sendable {
    /// After the user's first message the chat shows a "Turn On" row, which opens the
    /// system dialog.
    case automatic
    /// No row, and the SDK never opens the system dialog.
    case never
    /// The row is shown, and "Turn On" calls `ask` instead of the system dialog, so the
    /// host can route to its own soft ask. The row hides once the status is no longer
    /// `.notDetermined`.
    ///
    /// `ask` runs while the chat is presented from the topmost view controller, so a
    /// SwiftUI `.sheet` or `.fullScreenCover` on the app's root cannot present then and
    /// fails silently. Present the soft ask from the topmost controller, over the chat, or
    /// dismiss the chat first.
    case host(_ ask: @MainActor () -> Void)
}
