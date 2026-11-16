import Foundation

public enum MacLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case classic, magazine
    public var id: Self { self }
}

/// Previewing a layout never writes this preference. Only Apply or Later does.
/// Capture before bootstrap creates the installation's device identity.
@MainActor
public struct MacLayoutPreference {
    public static let layoutKey = "macLayoutMode"
    public static let introductionKey = "macLayoutIntroductionHandled"
    private let defaults: UserDefaults
    public let isExistingInstallation: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isExistingInstallation = defaults.string(forKey: DeviceIdentity.defaultsKey) != nil
            || defaults.data(forKey: ReaderStorage.bookmarkDefaultsKey) != nil
            || defaults.bool(forKey: ReaderStore.usesLocalLibraryKey)
            || defaults.bool(forKey: PlusCredential.configuredKey)
            || defaults.object(forKey: Self.layoutKey) != nil
    }

    public var layout: MacLayoutMode {
        MacLayoutMode(rawValue: defaults.string(forKey: Self.layoutKey) ?? "") ?? .classic
    }

    public var needsIntroduction: Bool { !defaults.bool(forKey: Self.introductionKey) }

    public func apply(_ layout: MacLayoutMode) {
        defaults.set(layout.rawValue, forKey: Self.layoutKey)
        defaults.set(true, forKey: Self.introductionKey)
    }

    public func deferIntroduction() {
        defaults.set(true, forKey: Self.introductionKey)
    }
}
