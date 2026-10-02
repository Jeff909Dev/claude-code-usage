import Foundation

public enum UsageAPIError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case decoding(String)
    case network(String)
}

public struct UsageAPI: Sendable {
    public static let baseURL = URL(string: "https://api.anthropic.com")!
    public static let usagePath = "/api/oauth/usage"
    public static let profilePath = "/api/oauth/profile"
    public static let betaHeader = "oauth-2025-04-20"

    let http: any HTTPClient
    let now: any DateProvider

    public init(http: any HTTPClient, now: any DateProvider) {
        self.http = http
        self.now = now
    }

    public func usage(accessToken: String) async throws -> UsageSnapshot {
        try Self.decodeUsage(try await get(Self.usagePath, token: accessToken), fetchedAt: now.now())
    }

    public func profile(accessToken: String) async throws -> Profile {
        try Self.decodeProfile(try await get(Self.profilePath, token: accessToken))
    }

    func get(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!.absoluteURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw UsageAPIError.network(String(error.code.rawValue))
        }
        switch response.statusCode {
        case 200..<300: return data
        // 403 is a refusal of this request, not of the login: refreshing the token would not help.
        case 401: throw UsageAPIError.unauthorized
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPIError.rateLimited(retryAfter: retry)
        default: throw UsageAPIError.http(response.statusCode)
        }
    }

    // MARK: Decoding

    public static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let dto: UsageDTO
        do { dto = try JSONDecoder().decode(UsageDTO.self, from: data) }
        catch { throw UsageAPIError.decoding(String(describing: error)) }

        var limits = (dto.limits ?? []).compactMap(\.value).compactMap(limit(from:))
        if limits.isEmpty { limits = legacyLimits(dto) }
        limits = limits.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)

        let surfaces = (dto.seven_day_breakdown?.rows ?? []).map {
            SurfaceShare(key: $0.key, displayName: $0.display_name ?? $0.key, percent: $0.percent ?? 0)
        }
        return UsageSnapshot(limits: limits, surfaces: surfaces,
                             extraUsageEnabled: dto.extra_usage?.is_enabled ?? false, fetchedAt: fetchedAt)
    }

    public static func decodeProfile(_ data: Data) throws -> Profile {
        let dto: ProfileDTO
        do { dto = try JSONDecoder().decode(ProfileDTO.self, from: data) }
        catch { throw UsageAPIError.decoding(String(describing: error)) }
        return Profile(accountUuid: dto.account.uuid, email: dto.account.email,
                       displayName: dto.account.display_name, fullName: dto.account.full_name,
                       organizationUuid: dto.organization.uuid, organizationName: dto.organization.name,
                       organizationType: dto.organization.organization_type,
                       rateLimitTier: dto.organization.rate_limit_tier,
                       subscriptionStatus: dto.organization.subscription_status,
                       hasClaudeMax: dto.account.has_claude_max ?? false,
                       hasClaudePro: dto.account.has_claude_pro ?? false)
    }

    static func rank(_ kind: String) -> Int {
        switch kind {
        case "session": return 0
        case "weekly_all": return 1
        case "weekly_scoped": return 2
        default: return 3
        }
    }

    static func limit(from dto: UsageDTO.LimitDTO) -> UsageLimit? {
        guard let percent = dto.percent else { return nil }
        let model = dto.scope?.modelName
        let surface = dto.scope?.surfaceName
        let isSession = dto.kind == "session" || dto.group == "session"
        let title: String
        switch dto.kind {
        case "session": title = "Session · 5h"
        case "weekly_all": title = "Week · all models"
        case "weekly_scoped": title = "Week · " + (model ?? surface ?? "scoped")
        default:
            let words = dto.kind.replacingOccurrences(of: "_", with: " ")
            title = words.prefix(1).uppercased() + words.dropFirst()
        }
        return UsageLimit(id: [dto.kind, model, surface].compactMap { $0 }.joined(separator: ":"),
                          kind: dto.kind, title: title, percent: percent, severity: dto.severity,
                          resetsAt: dto.resets_at.flatMap(ISODate.parse),
                          windowSeconds: isSession ? UsageLimit.sessionSeconds : UsageLimit.weekSeconds,
                          isActive: dto.is_active ?? false, modelName: model)
    }

    static func legacyLimits(_ dto: UsageDTO) -> [UsageLimit] {
        let windows: [(UsageDTO.Window?, String, String, TimeInterval, String?)] = [
            (dto.five_hour, "session", "Session · 5h", UsageLimit.sessionSeconds, nil),
            (dto.seven_day, "weekly_all", "Week · all models", UsageLimit.weekSeconds, nil),
            (dto.seven_day_opus, "weekly_scoped", "Week · Opus", UsageLimit.weekSeconds, "Opus"),
            (dto.seven_day_sonnet, "weekly_scoped", "Week · Sonnet", UsageLimit.weekSeconds, "Sonnet"),
        ]
        return windows.compactMap { window, kind, title, seconds, model in
            guard let utilization = window?.utilization else { return nil }
            return UsageLimit(id: [kind, model].compactMap { $0 }.joined(separator: ":"), kind: kind, title: title,
                              percent: utilization, severity: nil,
                              resetsAt: window?.resets_at.flatMap(ISODate.parse), windowSeconds: seconds,
                              isActive: false, modelName: model)
        }
    }
}

/// Decodes T, or nil when this element is malformed — one bad limit must not hide the others.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

struct UsageDTO: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct LimitDTO: Decodable {
        let kind: String
        let group: String?
        let percent: Double?
        let severity: String?
        let resets_at: String?
        let is_active: Bool?
        let scope: ScopeDTO?
    }

    struct ScopeDTO: Decodable {
        struct Named: Decodable { let display_name: String? }
        enum CodingKeys: String, CodingKey { case model, surface }
        let modelName: String?
        let surfaceName: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelName = (try? c.decodeIfPresent(Named.self, forKey: .model))?.display_name
            let namedSurface = (try? c.decodeIfPresent(Named.self, forKey: .surface))?.display_name
            let plainSurface = try? c.decodeIfPresent(String.self, forKey: .surface)
            surfaceName = namedSurface ?? plainSurface
        }
    }

    struct Breakdown: Decodable {
        struct Row: Decodable {
            let key: String
            let display_name: String?
            let percent: Double?
        }
        let rows: [Row]?
    }

    struct Extra: Decodable { let is_enabled: Bool? }

    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let limits: [Failable<LimitDTO>]?
    let seven_day_breakdown: Breakdown?
    let extra_usage: Extra?
}

struct ProfileDTO: Decodable {
    struct AccountDTO: Decodable {
        let uuid: String
        let email: String
        let display_name: String?
        let full_name: String?
        let has_claude_max: Bool?
        let has_claude_pro: Bool?
    }
    struct OrganizationDTO: Decodable {
        let uuid: String
        let name: String?
        let organization_type: String?
        let rate_limit_tier: String?
        let subscription_status: String?
    }
    let account: AccountDTO
    let organization: OrganizationDTO
}
