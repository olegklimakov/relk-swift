import SwiftUI
import UIKit

/// Presents the chat from the topmost presented controller of the foreground
/// scene's normal-level window (see `presentationWindow(among:)`).
///
/// A SwiftUI `.sheet` on the host's root can't present while that view already
/// presents a sheet or full-screen cover (a run, a paywall), and its binding
/// then stays `true`, so later taps do nothing. Presenting from whatever is on
/// top works over any of those.
///
/// Every `.relkChat` instance shares this presenter and identifies itself
/// with an owner token: only the owner's `false` closes the chat, and a caller
/// turned away because another one is showing gets its binding reset at once.
@MainActor
final class ChatPresenter {
    static let shared = ChatPresenter()

    struct Request {
        let id = UUID()
        let owner: UUID
        let screen: String?
        var meta: [String: RelkMetaValue]
        let tint: Color?
        let onDismissed: @MainActor () -> Void
    }

    private enum State {
        case idle
        case waiting(Request, attempt: Int)
        case presented(ChatHostingController, Request)
    }

    /// Long enough to outlast a sheet or cover transition (~0.5 s) several times over.
    static let maxAttempts = 40
    static let retryDelay: TimeInterval = 0.05

    private var state = State.idle
    private let topmost: @MainActor () -> UIViewController?
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        topmost: @escaping @MainActor () -> UIViewController? = ChatPresenter.foregroundTopmost,
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        }
    ) {
        self.topmost = topmost
        self.schedule = schedule
    }

    var isIdle: Bool {
        if case .idle = state { true } else { false }
    }

    var presentedController: ChatHostingController? {
        if case .presented(let controller, _) = state { controller } else { nil }
    }

    func present(
        owner: UUID,
        screen: String?,
        meta: [String: RelkMetaValue],
        tint: Color?,
        onDismissed: @escaping @MainActor () -> Void
    ) {
        healIfStale()
        switch state {
        case .idle:
            let request = Request(owner: owner, screen: screen, meta: meta, tint: tint, onDismissed: onDismissed)
            attempt(request, number: 0)
        case .waiting(let request, _), .presented(_, let request):
            if request.owner != owner { onDismissed() }
        }
    }

    func dismiss(owner: UUID) {
        dismiss(owner: owner, attempt: 0)
    }

    /// The owner's new meta, for the messages sent from now on.
    func update(owner: UUID, meta: [String: RelkMetaValue]) {
        switch state {
        case .idle:
            break
        case .waiting(var request, let number):
            guard request.owner == owner else { return }
            request.meta = meta
            state = .waiting(request, attempt: number)
        case .presented(let controller, var request):
            guard request.owner == owner else { return }
            request.meta = meta
            controller.meta = meta
            state = .presented(controller, request)
        }
    }

    private func dismiss(owner: UUID, attempt number: Int) {
        healIfStale()
        switch state {
        case .idle:
            break
        case .waiting(let request, _):
            guard request.owner == owner else { return }
            state = .idle
        case .presented(let controller, let request):
            guard request.owner == owner else { return }
            // UIKit ignores a dismissal requested while the presentation is still running.
            if !controller.hasAppeared {
                guard number < Self.maxAttempts else {
                    finish(request.id)
                    return
                }
                schedule(Self.retryDelay) { [weak self] in
                    guard let self, case .presented(_, let current) = self.state, current.id == request.id else { return }
                    self.dismiss(owner: owner, attempt: number + 1)
                }
                return
            }
            // Dismissing from the presenter also takes down whatever the chat
            // presents itself (the image viewer); `controller.dismiss` would
            // close only that child.
            controller.presentingViewController?.dismiss(animated: true) { [weak self] in
                self?.finish(request.id)
            }
        }
    }

    private func attempt(_ request: Request, number: Int) {
        guard let presenter = topmost(), presenter.transitionCoordinator == nil else {
            guard number < Self.maxAttempts else {
                state = .idle
                request.onDismissed()
                return
            }
            state = .waiting(request, attempt: number)
            schedule(Self.retryDelay) { [weak self] in
                guard let self, case .waiting(let pending, _) = self.state, pending.id == request.id else { return }
                self.attempt(pending, number: number + 1)
            }
            return
        }

        let owner = request.owner
        let controller = ChatHostingController(screen: request.screen, meta: request.meta, tint: request.tint) { [weak self] in
            self?.dismiss(owner: owner)
        }
        controller.onDismissed = { [weak self] in self?.finish(request.id) }
        controller.modalPresentationStyle = .pageSheet
        state = .presented(controller, request)
        presenter.present(controller, animated: true)
    }

    /// Idempotent: the dismissal completion and `viewDidDisappear` can both report.
    private func finish(_ requestID: UUID) {
        guard case .presented(_, let request) = state, request.id == requestID else { return }
        state = .idle
        request.onDismissed()
    }

    /// The host can tear the chat down without UIKit telling it, by dismissing
    /// a controller underneath it; a chat no longer on screen is treated as gone.
    private func healIfStale() {
        guard case .presented(let controller, let request) = state else { return }
        let detached = controller.presentingViewController == nil
        let offScreen = controller.hasAppeared
            && controller.viewIfLoaded?.window == nil
            && controller.presentedViewController == nil
            && !controller.isBeingDismissed
        if detached || offScreen { finish(request.id) }
    }

    /// `nil` while something on the way can't present: no usable window, a controller
    /// mid-transition, or an alert, which can't present and must not be covered.
    static func foregroundTopmost() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return presentationWindow(among: windows)?.rootViewController.flatMap(topmost(from:))
    }

    /// A host's lock or privacy cover is a window above `.normal` and is often key; the
    /// chat presented from it would show the thread over the lock screen. An inactive
    /// scene still counts: a host running Face ID on unlock keeps it inactive for seconds.
    /// A TV or monitor scene is often active while the phone's is inactive (Control Center
    /// over a run on a TV), and nobody can touch the chat there.
    static func presentationWindow<Window: PresentationCandidate>(among windows: [Window]) -> Window? {
        let usable = windows.filter {
            $0.windowLevel == .normal && !$0.isHidden && $0.sceneRole != .windowExternalDisplayNonInteractive
        }
        for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
            let inScene = usable.filter { $0.sceneActivationState == state }
            if let window = inScene.first(where: \.isKeyWindow) ?? inScene.first { return window }
        }
        return nil
    }

    static func topmost(from root: UIViewController) -> UIViewController? {
        var top = root
        while let next = top.presentedViewController {
            guard !next.isBeingPresented, !next.isBeingDismissed, !(next is UIAlertController) else { return nil }
            top = next
        }
        return top
    }
}

@MainActor
protocol PresentationCandidate {
    var windowLevel: UIWindow.Level { get }
    var isKeyWindow: Bool { get }
    var isHidden: Bool { get }
    var sceneActivationState: UIScene.ActivationState { get }
    var sceneRole: UISceneSession.Role? { get }
}

extension UIWindow: PresentationCandidate {
    var sceneActivationState: UIScene.ActivationState {
        windowScene?.activationState ?? .unattached
    }

    var sceneRole: UISceneSession.Role? {
        windowScene?.session.role
    }
}

final class ChatHostingController: UIHostingController<AnyView> {
    var onDismissed: (@MainActor () -> Void)?
    private(set) var hasAppeared = false
    var meta: [String: RelkMetaValue] {
        didSet { rootView = Self.root(screen: screen, meta: meta, tint: tint, onDone: onDone) }
    }

    private let screen: String?
    private let tint: Color?
    private let onDone: @MainActor () -> Void

    init(screen: String?, meta: [String: RelkMetaValue], tint: Color?, onDone: @escaping @MainActor () -> Void) {
        self.screen = screen
        self.meta = meta
        self.tint = tint
        self.onDone = onDone
        super.init(rootView: Self.root(screen: screen, meta: meta, tint: tint, onDone: onDone))
    }

    private static func root(
        screen: String?,
        meta: [String: RelkMetaValue],
        tint: Color?,
        onDone: @escaping @MainActor () -> Void
    ) -> AnyView {
        AnyView(RelkChatView(screen: screen, meta: meta, onDone: onDone).tint(tint))
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }

    /// Catches swipe-down, which reports nowhere else.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        onDismissed?()
    }
}
