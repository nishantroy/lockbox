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
    static let lifetime: Int64 = 5 * 60
    private static let clockSkew: Double = 30.0
    private static let maximumIssuanceAge: Double = Double(lifetime) + clockSkew

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
    /// A unique, non-secret route ID. It is used for queue deduplication only;
    /// the custom URL remains unauthenticated navigation data.
    let id: String
    let expiresAt: Date

    static func url(for action: Action, now: Date = Date()) -> URL? {
        guard let issued = integerSeconds(now),
              !issued.addingReportingOverflow(lifetime).overflow,
              let nonce = UUID(uuidString: UUID().uuidString.lowercased()) else { return nil }
        let expires = issued.addingReportingOverflow(lifetime).partialValue
        let nonceString = nonce.uuidString.lowercased()
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/v\(version)/\(path(for: action))"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "issued", value: String(issued)),
            URLQueryItem(name: "expires", value: String(expires)),
            URLQueryItem(name: "nonce", value: nonceString)
        ]
        if case .focus(let preset) = action {
            query.append(URLQueryItem(name: "duration", value: preset.rawValue))
        }
        components.queryItems = query
        return components.url
    }

    static func parse(_ url: URL, now: Date = Date()) -> Self? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              url.isFileURL == false,
              url.scheme == scheme,
              url.host == host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil else { return nil }
        let nowSeconds = Double(now.timeIntervalSinceReferenceDate)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let components,
              let path = canonicalPath(components),
              let action = action(for: path, queryItems: components.queryItems ?? []) else {
            return nil
        }
        let query = components.queryItems ?? []
        guard query.count == Set(query.map(\.name)).count else { return nil }
        let allowed = Set(action == .focus(.thirtyMinutes) || action == .focus(.oneHour)
            ? ["issued", "expires", "nonce", "duration"]
            : ["issued", "expires", "nonce"])
        guard Set(query.map(\.name)) == allowed,
              let issued = integerSeconds(query, named: "issued"),
              let expires = integerSeconds(query, named: "expires"),
              !expires.subtractingReportingOverflow(issued).overflow,
              expires.subtractingReportingOverflow(issued).partialValue == lifetime,
              let nonce = queryValue(query, named: "nonce"),
              isCanonicalNonce(nonce),
              Double(issued) <= nowSeconds + clockSkew,
              nowSeconds - Double(issued) <= maximumIssuanceAge,
              nowSeconds < Double(expires) else { return nil }

        if case .focus(let preset) = action,
           queryValue(query, named: "duration") != preset.rawValue {
            return nil
        }
        return Self(action: action, id: nonce, expiresAt: Date(timeIntervalSinceReferenceDate: Double(expires)))
    }

    private static func path(for action: Action) -> String {
        switch action {
        case .focus: return "focus"
        case .status: return "status"
        case .recovery: return "recovery"
        }
    }

    private static func canonicalPath(_ components: URLComponents) -> String? {
        let expected: Set<String> = ["/v\(version)/focus", "/v\(version)/status", "/v\(version)/recovery"]
        // Check the encoded form as well as the decoded path so percent-escaped
        // segments and slash normalization cannot create alternate spellings.
        guard expected.contains(components.path), components.percentEncodedPath == components.path else { return nil }
        return components.path
    }

    private static func action(for path: String, queryItems: [URLQueryItem]) -> Action? {
        switch path {
        case "/v\(version)/focus":
            guard let value = queryValue(queryItems, named: "duration") else { return nil }
            return FocusPreset(rawValue: value).map(Action.focus)
        case "/v\(version)/status": return .status
        case "/v\(version)/recovery": return .recovery
        default: return nil
        }
    }

    private static func queryValue(_ queryItems: [URLQueryItem], named name: String) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }

    private static func isCanonicalNonce(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func integerSeconds(_ date: Date) -> Int64? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date.timeIntervalSinceReferenceDate >= Double(Int64.min),
              date.timeIntervalSinceReferenceDate < Double(Int64.max) else { return nil }
        return Int64(date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private static func integerSeconds(_ queryItems: [URLQueryItem], named name: String) -> Int64? {
        guard let value = queryValue(queryItems, named: name),
              !value.isEmpty,
              value == "0" || value.first != "0",
              value != "-0",
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 45 }),
              value.utf8.filter({ $0 == 45 }).count <= 1,
              !value.dropFirst().contains("-") else { return nil }
        guard let seconds = Int64(value) else { return nil }
        return String(seconds) == value ? seconds : nil
    }
}
