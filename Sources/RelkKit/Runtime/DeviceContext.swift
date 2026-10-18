import Foundation

enum DeviceContext {
    /// The server rejects context strings over 100 characters.
    static let maxFieldLength = 100

    static func current(screen: String?, bundle: Bundle = .main) -> MessageContext {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return MessageContext(
            appVersion: (info["CFBundleShortVersionString"] as? String).map(clamp),
            build: (info["CFBundleVersion"] as? String).map(clamp),
            os: "iOS \(osVersion)",
            device: clamp(machineIdentifier()),
            locale: clamp(Locale.current.identifier),
            language: bundle.preferredLocalizations.first.map(clamp),
            screen: screen.map(clamp)
        )
    }

    static func machineIdentifier() -> String {
        // `utsname.machine` is the host's "arm64" inside the simulator.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Counted in Unicode scalars, as the server counts.
    private static func clamp(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(maxFieldLength)))
    }
}
