import Foundation

enum LLMCenterUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case invalidToken
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach LLM Center. Check your connection."
        case .invalidResponse:
            return "LLM Center usage data unavailable. Try again later."
        case .invalidToken:
            return "LLM Center login expired. Run `llmctl auth login` again, then refresh."
        case .requestFailed(let status):
            return "LLM Center request failed (HTTP \(status))."
        }
    }
}

/// Calls the same endpoints the LLM Center web app uses, so every figure is the platform's own
/// accounting — no local summation or pricing. The personal scope (`scope: "PERSONAL"`, `freeUser: 1`)
/// is what the site's 个人额度 view sends.
struct LLMCenterUsageClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The current user's department membership: the dept whose member-quota row is this user's own
    /// monthly quota. `GET {api}/llm/api/department/my`.
    func fetchMyDepartment(api: String, token: String) async throws -> (userId: String, deptId: Int) {
        let response = try await get(api: api, token: token, path: "llm/api/department/my")
        guard let object = ProviderParse.jsonObject(response.body),
              ProviderParse.number(object["code"]) == 0,
              let data = object["data"] as? [String: Any],
              let userId = data["userId"] as? String
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        let deptId = Int(ProviderParse.number(data["deptId"]) ?? 0)
        return (userId, deptId)
    }

    /// Every department member with their monthly quota fields — including this user's own row
    /// (`memberQuota`, `effectiveQuota`, `spentAmount`, `remainingQuota`). `GET
    /// {api}/llm/api/department/{deptId}/members`.
    func fetchDepartmentMembers(api: String, token: String, deptId: Int) async throws -> [[String: Any]] {
        let response = try await get(api: api, token: token, path: "llm/api/department/\(deptId)/members")
        guard let object = ProviderParse.jsonObject(response.body),
              ProviderParse.number(object["code"]) == 0,
              let data = object["data"] as? [[String: Any]]
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        return data
    }

    /// The official period summary for one day range: total cost and tokens. `POST
    /// {api}/llm/api/usage/statistics`.
    func fetchStatistics(api: String, token: String, from: Date, to: Date) async throws -> (cost: Double, tokens: Int) {
        let body: [String: Any] = [
            "startDate": Self.apiDate(from),
            "endDate": Self.apiDate(to),
            "scope": "PERSONAL",
            "freeUser": 1
        ]
        let response = try await post(api: api, token: token, path: "llm/api/usage/statistics", body: body)
        guard let object = ProviderParse.jsonObject(response.body),
              ProviderParse.number(object["code"]) == 0,
              let data = object["data"] as? [String: Any]
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        let cost = max(0, ProviderParse.number(data["totalCost"]) ?? 0)
        let tokens = max(0, Int(ProviderParse.number(data["totalTokens"]) ?? 0))
        return (cost, tokens)
    }

    /// The official per-day-per-model rows for a date range (one row per model per day, with cost and
    /// tokens). `POST {api}/llm/api/usage/user-model-details`.
    func fetchModelDetails(api: String, token: String, from: Date, to: Date) async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "startDate": Self.apiDate(from),
            "endDate": Self.apiDate(to),
            "scope": "PERSONAL",
            "freeUser": 1,
            "page": 1,
            "pageSize": 500
        ]
        let response = try await post(api: api, token: token, path: "llm/api/usage/user-model-details", body: body)
        guard let object = ProviderParse.jsonObject(response.body),
              ProviderParse.number(object["code"]) == 0,
              let data = object["data"] as? [String: Any],
              let rows = data["detailList"] as? [[String: Any]]
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        return rows
    }

    private func post(api: String, token: String, path: String, body: [String: Any]) async throws -> HTTPResponse {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        guard let url = URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appendingPathComponent(path)
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Accept": "application/json"
                ],
                body: payload,
                timeout: 20
            ))
        } catch {
            throw LLMCenterUsageError.connectionFailed
        }
        return try Self.classify(response)
    }

    private func get(api: String, token: String, path: String) async throws -> HTTPResponse {
        guard let url = URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?
            .appendingPathComponent(path)
        else {
            throw LLMCenterUsageError.invalidResponse
        }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Accept": "application/json"
                ],
                timeout: 20
            ))
        } catch {
            throw LLMCenterUsageError.connectionFailed
        }
        return try Self.classify(response)
    }

    private static func classify(_ response: HTTPResponse) throws -> HTTPResponse {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw LLMCenterUsageError.invalidToken
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LLMCenterUsageError.requestFailed(response.statusCode)
        }
        return response
    }

    /// The `YYYY-MM-DD` local-date form these endpoints expect (they compare against Beijing wall-clock
    /// dates and ignore timezone suffixes).
    private static func apiDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
