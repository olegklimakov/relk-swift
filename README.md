# Integrating Relk into an iOS app

iOS 17+, Swift 6, no third-party dependencies.

## 1. Add the package

Xcode → File → Add Package Dependencies → `https://github.com/olegklimakov/relk-swift`,
product **RelkKit**.
In a `Package.swift`: `.package(url: "https://github.com/olegklimakov/relk-swift", from: "0.4.0")` and `.product(name: "RelkKit", package: "relk-swift")`.

## 2. Configure at launch and forward push callbacks

```swift
import RelkKit
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Relk.configure(appKey: "rk_pub_…")   // notificationPrompt: see "What the SDK asks the user for"
        UNUserNotificationCenter.current().delegate = self   // before launch ends, so a cold-start tap is delivered
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Relk.registerDeviceToken(token)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if !Relk.handle(response) {
            // …your own pushes
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Relk.presentationOptions(for: notification) ?? [.banner, .list, .sound])
    }
}
```

Use the completion-handler variants, not the `async` ones: a `nonisolated async`
implementation finishes on a background thread, and UIKit aborts when the
`didReceive` completion runs off the main thread (it snapshots the UI there).

In a SwiftUI app, attach it with `@UIApplicationDelegateAdaptor(AppDelegate.self)`.
If you already have a delegate, add the calls to it: Relk recognises its
own pushes by the `relk` key and returns `false`/`nil` for everything else.

## 3. Show the chat

Attach the modifier **once, at the app root**, so a tapped Relk push opens the
chat from any screen:

```swift
WindowGroup {
    RootView()
        .relkChat(
            isPresented: $isFeedbackPresented,
            screen: currentScreenName,
            tint: .orange,                 // your brand colour
            presentsPushes: !showSplash    // hold push taps until the app is ready
        )
}
```

- Open it by setting `isFeedbackPresented = true`, from any screen. The chat is
  presented as a page sheet from whatever is on top at that moment, so it also
  appears over your own sheets and full-screen covers (a paywall, a workout).
  The binding goes back to `false` however the chat is closed.
- The chat is only presented from a visible window at `.normal` level in a
  foreground scene (active, or inactive while Face ID or Control Center is up), never
  from a window of your own above that level. Keep a lock, a privacy blur or a
  passcode screen in a window above `.normal` (say `.alert + 1`): it then stays on
  top even while it is the key window, and a chat opened from code or a push
  meanwhile appears under it. A cover at `.normal` made key would be chosen and
  covered by the chat. While your cover holds key, the chat is not live: it does not
  mark replies read, and reply banners still show.
- A presentation that can't happen within about two seconds (no such window, or
  your own alert on top) is dropped and the binding goes back to `false`. To open a
  tapped push only after unlocking, pass `presentsPushes: !isLocked`.
- `tint` colours the chat. A sheet doesn't inherit the presenter's `.tint`;
  without it the chat uses your AccentColor asset.
- `presentsPushes`: while `false`, a tapped reply push waits and opens the chat
  as soon as it turns `true`. On a cold launch from a push, this keeps the chat
  from appearing over your splash or onboarding.
- `screen` is sent with every message so you see where the user was.
- `meta` is your own JSON, attached to every message sent while the chat is open with it,
  and shown to you under the message in both admin apps as "From the app · unverified".
  A chat opened by a tapped push gets the root modifier's `meta`, so keep the root's
  empty and pass a report's meta where the report is raised (below). Every mounted
  `.relkChat` answers a push tap, so give any other one that carries meta
  `presentsPushes: false`. A change applies from the next message.

`RelkChatView(screen:meta:)` also works in your own sheet, but then push taps
won't open it for you. It is the place for a chat about one thing, say a report about a
post:

```swift
.sheet(isPresented: $isReporting) {
    RelkChatView(screen: "Post", meta: [
        "kind": "report",
        "post": ["id": "\(post.id)", "day": post.day],
    ])
}
```

`meta` is `[String: RelkMetaValue]`, a JSON enum with literals for strings, numbers,
booleans, `nil`, arrays and objects; interpolate a value that is not a literal
(`"\(post.id)"`). Numbers are `Double`s, so send ids as strings. Limits: 4 KB as compact
JSON, 3 levels of nesting, keys up to 64 characters, numbers within ±2^53. Over a limit the SDK logs
it and drops the meta, and the message still goes. Relk never sends meta to Telegram.

> **Meta is your data, under your privacy label.** Relk stores it with the message and
> shows it only to your workspace, but it travels from the user's device, so the user
> could change it: treat it as a hint, and check anything that matters on your own
> server. Put no secrets in it (tokens, keys, passwords), and nothing personal beyond
> what the message needs; ids your server can resolve are better than names or emails.
> Whatever it holds, declare it on your App Store privacy label with the rest of what
> you send to Relk.

**Unread badge:** `Relk.unreadCount` is observable, so `.badge(Relk.unreadCount)`
on the row updates by itself. It is refreshed at launch, on foreground and on pushes,
and drops to 0 as the user reads the replies in the chat.

**Welcome:** a greeting from you, at the top of the chat, from the first open on:

```swift
Relk.configure(
    appKey: "rk_pub_…",
    welcome: RelkWelcome(
        "feedback.welcome",          // a key in your own String Catalog
        name: "Oleg",
        avatar: Image("developer")   // optional, drawn as a 32 pt circle
    )
)
```

The text is a `LocalizedStringResource`, so it is translated with your app. A literal
resolves in your main bundle; strings kept in a Swift package need
`LocalizedStringResource("feedback.welcome", bundle: .atURL(Bundle.module.bundleURL))`. The SDK
draws it as your first message; it is never sent, so it creates no conversation and
does not reach your inbox or Telegram. Without `welcome`, an empty chat shows the
SDK's own "Write to the developer". Changing the text takes an app release.

## 4. Push capability

Add the **Push Notifications** capability (`aps-environment` entitlement). Without
it the chat works, but replies only show up the next time the chat is opened. The
SDK picks the sandbox or production APNs gateway from the provisioning profile.

## Sign-out and account deletion

The conversation belongs to the install, not to your user: a token in the Keychain names
it, and it survives a reinstall. It does not follow a backup to a new phone: there the chat
starts a new conversation, and the old one stays in your inbox. A backup made before your app
first ran a RelkKit with this rule still holds the token and carries the conversation along.
Two calls end it.

```swift
func signOut() {
    Relk.reset()
    // …your own sign-out
}

func deleteAccount() async throws {
    try await Relk.deleteUserData()   // throws: stop here, keep the user signed in, retry
    // …your own account deletion
}
```

- **`Relk.reset()`**, on sign-out, so the next person on the phone does not see the
  previous one's conversation. It drops the Keychain token and the chat's history, drafts
  and cached images, removes Relk's notifications from Notification Center, sets
  `unreadCount` to 0, and asks the server (`DELETE
  /v1/device-token`) to stop pushing the old conversation's replies to this device. Offline,
  that request fails and is not retried; the device then keeps getting those replies' pushes
  until the chat opens again and the new user's push token registration moves the token. The
  next time the chat opens, the SDK registers a new, empty conversation. The old one stays on
  the server and in your inbox.
- **`Relk.deleteUserData()`**, on account deletion (App Store Guideline 5.1.1(v)). It
  deletes the conversation on the server (`DELETE /v1/thread`): every message with its
  `meta`, the images and the push tokens at once, and, when replies go through a Telegram
  group, the user's topic shortly after. Then it does what `reset()` does. On failure it
  throws `RelkDataDeletionError` and keeps the token and the chat so the call can be
  repeated; a deletion whose answer was lost succeeds again:

  | `RelkDataDeletionError` | Meaning |
  |---|---|
  | `.unreachable` | No answer from the server (offline); try again later. |
  | `.refused(status:)` | The server answered with that HTTP status; try again later. |
  | `.keychainUnavailable` | The device has not been unlocked since it restarted; try again once it has. |
  | `.notConfigured` | Called before `Relk.configure`. |

  Do not call `reset()` after a failure: without the token nothing can delete that
  conversation from the device any more. Once it has succeeded a second call deletes
  nothing. If the chat was never opened there is nothing on the server, and it only resets.
  The conversation disappears from your inbox at once. Backups keep it for up to 15 days.
  A Telegram topic the bot could not delete (it needs the **Delete messages** right) stays
  in the group, renamed "🗑 Deleted by the user · delete this topic", until you delete it;
  topics in a group you were connected to before are not touched. Pushes about the
  conversation already shown on your own devices, and Telegram posts you copied elsewhere,
  stay where they are. See `DELETE /v1/thread` in docs/api.md.

Both act on this install's conversation only. A user who wrote from two devices has two
conversations, and each install deletes its own.

## What the SDK asks the user for, and when

- **Notifications:** by default, don't request permission yourself. The chat shows an
  inline "Get notified when the developer replies · Turn On" row once the user has
  sent their first message and has never been asked, and "Turn On" opens the system
  dialog. After a grant, and at every launch where notifications are already allowed,
  the SDK calls `registerForRemoteNotifications()` itself, however they were granted.

  iOS shows that dialog once per install. If your app asks at a moment of its own,
  behind a soft ask of its own, pass `notificationPrompt` so the chat doesn't spend
  it:

  ```swift
  Relk.configure(appKey: "rk_pub_…", notificationPrompt: .host { showNotificationSoftAsk() })
  ```

  | `notificationPrompt` | Row in the chat | "Turn On" |
  |---|---|---|
  | `.automatic` (default) | shown | opens the system dialog |
  | `.host { … }` | shown | calls your closure on the main actor; your code asks |
  | `.never` | not shown | — |

  Under `.host` and `.never` the SDK never calls `requestAuthorization`. Under `.host`
  the row hides once the status is no longer "not determined" (allowed, provisional or
  denied): the SDK re-reads it whenever the app becomes
  active, so it notices the answer to your dialog, or a change in Settings, on its own,
  and registers for remote notifications as soon as they are allowed, with the chat
  open or closed. If the user dismisses your soft ask without deciding, the row stays.

  Your closure runs while the chat is on screen, presented from the topmost view
  controller. A `.sheet` or `.fullScreenCover` attached to your root view cannot present
  then, and SwiftUI drops it without an error. Either present the soft ask from the
  topmost controller, over the chat, or dismiss the chat first (set the `.relkChat`
  binding to `false`) and ask from your own screen.
- **Photos:** none. Screenshots are picked with `PhotosPicker`, which runs out of
  process and needs no permission or usage string.

## Localization

Strings ship in en, ru, uk, de, es, fr, it, nl, pl, pt-BR, tr, ja, ko, zh-Hans and
zh-Hant. iOS shows the SDK in your app's resolved language, so the SDK only
appears in the languages your app declares (its `.lproj` folders or
`CFBundleLocalizations`). Every message carries that display language
(`Bundle.main.preferredLocalizations.first`) alongside the region `locale`; the
server titles reply pushes in it.

## Privacy label

The SDK ships a `PrivacyInfo.xcprivacy` (no tracking, no required-reason APIs).
What it sends to the Relk server, none of it used for tracking:

| Data | App Store category |
|---|---|
| Message text | Customer Support; Other User Content |
| Attached screenshots, re-encoded on device with EXIF/GPS removed | Photos or Videos |
| App version and build, iOS version, device model, region (`locale`), the app's display language, screen name | Other Diagnostic Data |
| Your `meta`, if you pass one | whatever category its contents fall under (an id of a user's content: Other User Content) |
| A random per-install token (Keychain), which the thread is stored under, and the APNs push token | User ID |

Messages are stored under that per-install identifier until `Relk.deleteUserData()` deletes
them (and for up to 15 days more in backups). Apple counts data tied to
any identifier as linked, even a pseudonymous one, so declare all of the above
under **Data Linked to You**, purpose **App Functionality**, and
**Data Used to Track You: No**.

The SDK also sends your app's bundle ID, so the dashboard can tell you when the
app has a different bundle ID in Relk, which Apple refuses pushes for. It names
your app, not the user, so it is not part of the label.
