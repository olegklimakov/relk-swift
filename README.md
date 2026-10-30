# Integrating Relk into an iOS app

iOS 17+, Swift 6, no third-party dependencies.

## 1. Add the package

Xcode → File → Add Package Dependencies → `https://github.com/olegklimakov/relk-swift`,
product **RelkKit**.
In a `Package.swift`: `.package(url: "https://github.com/olegklimakov/relk-swift", from: "0.3.0")` and `.product(name: "RelkKit", package: "relk-swift")`.

## 2. Configure at launch and forward push callbacks

```swift
import RelkKit
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Relk.configure(appKey: "rk_pub_…")
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
- `tint` colours the chat. A sheet doesn't inherit the presenter's `.tint`;
  without it the chat uses your AccentColor asset.
- `presentsPushes`: while `false`, a tapped reply push waits and opens the chat
  as soon as it turns `true`. On a cold launch from a push, this keeps the chat
  from appearing over your splash or onboarding.
- `screen` is sent with every message so you see where the user was.

`RelkChatView(screen:)` also works in your own sheet, but then push taps
won't open it for you.

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

## What the SDK asks the user for, and when

- **Notifications:** don't request permission yourself. The chat shows an inline
  "Get notified when the developer replies · Turn On" row once the user has sent
  their first message and has never been asked. After a grant, and at every launch
  where notifications are already allowed, the SDK calls
  `registerForRemoteNotifications()` itself.
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
| A random per-install token (Keychain), which the thread is stored under, and the APNs push token | User ID |

Messages are stored under that per-install identifier. Apple counts data tied to
any identifier as linked, even a pseudonymous one, so declare all of the above
under **Data Linked to You**, purpose **App Functionality**, and
**Data Used to Track You: No**.

The SDK also sends your app's bundle ID, so the dashboard can tell you when the
app has a different bundle ID in Relk, which Apple refuses pushes for. It names
your app, not the user, so it is not part of the label.
