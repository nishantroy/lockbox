import Foundation

/// Versioned, fail-closed routes used only to ask the app to present a normal
/// confirmation or status screen. Parsing this URL never performs enforcement.
struct QuickActionRoute: Equatable, Sendable {
    enum Destination: Hashable {
        case recovery
    }

    static let scheme = "phonelockbox"
    static let host = "quick-action"
    static let version = 1
    private static let lifetime: TimeInterval = 5 * 60
    private static let clockSkew: TimeInterval = 30

    enum FocusPreset: String, Equatable, Sendable {
        case thirtyMinutes = "30"
        case oneHour = "60"
    }

    enum Action: Equatable, Sendable {
        case focus(FocusPreset)
        case status
        case recovery
    }

    let action: Action
    let expiresAt: Date

    static func url(for action: Action, now: Date = Date()) -> URL? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let expires = now.addingTimeInterval(lifetime)
        guard expires.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/v\(version)/\(path(for: action))"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "issued", value: seconds(now)),
            URLQueryItem(name: "expires", value: seconds(expires))
        ]
        if case .focus(let preset) = action {
            query.append(URLQueryItem(name: "duration", value: preset.rawValue))
        }
        components.queryItems = query
        return components.url
    }

    static func parse(_ url: URL, now: Date = Date()) -> Self? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              url.scheme == scheme,
              url.host == host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let components,
              components.path.split(separator: "/", omittingEmptySubsequences: true).count == 2,
              let versionPart = components.path.split(separator: "/", omittingEmptySubsequences: true).first,
              versionPart == "v\(version)",
              let actionPart = components.path.split(separator: "/", omittingEmptySubsequences: true).last,
              let action = action(for: String(actionPart), queryItems: components.queryItems ?? []) else {
            return nil
        }
        let query = components.queryItems ?? []
        guard query.count == Set(query.map(\.name)).count,
              let issued = seconds(query, named: "issued"),
              let expires = seconds(query, named: "expires"),
              expires > issued,
              issued <= now.timeIntervalSinceReferenceDate + clockSkew,
              now.timeIntervalSinceReferenceDate < expires else { return nil }

        let allowed = Set(action == .status ? ["issued", "expires"] :
            action == .recovery ? ["issued", "expires"] : ["issued", "expires", "duration"])
        guard Set(query.map(\.name)) == allowed else { return nil }
        if case .focus(let preset) = action,
           seconds(query, named: "duration") != Double(preset.rawValue) {
            return nil
        }
        return Self(action: action, expiresAt: Date(timeIntervalSinceReferenceDate: expires))
    }

    private static func path(for action: Action) -> String {
        switch action {
        case .focus: return "focus"
        case .status: return "status"
        case .recovery: return "recovery"
        }
    }

    private static func action(for path: String, queryItems: [URLQueryItem]) -> Action? {
        switch path {
        case "focus":
            guard let value = queryItems.first(where: { $0.name == "duration" })?.value else { return nil }
            return FocusPreset(rawValue: value).map(Action.focus)
        case "status": return .status
        case "recovery": return .recovery
        default: return nil
        }
    }

    private static func seconds(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSinceReferenceDate)
    }

    private static func seconds(_ queryItems: [URLQueryItem], named name: String) -> Double? {
        guard let value = queryItems.first(where: { $0.name == name })?.value,
              let seconds = Double(value), seconds.isFinite else { return nil }
        return seconds
    }
}
