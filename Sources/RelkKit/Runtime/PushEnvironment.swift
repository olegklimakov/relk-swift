import Foundation

enum PushEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    static func detect(bundle: Bundle = .main) -> PushEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        // App Store and TestFlight builds carry no embedded profile and use production APNs.
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url)
        else { return .production }
        return fromProvisioningProfile(profile)
        #endif
    }

    /// The profile is a CMS envelope around an XML plist; the plist is found
    /// by its markers instead of verifying the signature.
    static func fromProvisioningProfile(_ profile: Data) -> PushEnvironment {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile[start.lowerBound..<end.upperBound],
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              entitlements["aps-environment"] as? String == "development"
        else { return .production }
        return .sandbox
    }
}

extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
