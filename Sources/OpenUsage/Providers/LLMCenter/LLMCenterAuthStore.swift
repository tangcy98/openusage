import Foundation

/// The LLM Center credential the `llmctl` CLI left on the machine: the API base URL plus the Rosefinch
/// bearer token it uses for every request. OpenUsage reads this directly from disk — it never asks the
/// user to paste a token and never calls out to `llmctl`.
struct LLMCenterAuth: Hashable, Sendable {
    var apiBaseURL: String
    var webToken: String
}

enum LLMCenterAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable(detail: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to LLM Center. Run `llmctl auth login` to sign in, then refresh."
        case .credentialsUnreadable:
            return "Couldn't read the LLM Center login. Re-run `llmctl auth login`, then refresh."
        }
    }
}

/// Reads `~/Library/Application Support/llmctl/config.json` — the file `llmctl auth login` writes on
/// Darwin — which holds `{ "api": "<base URL>", "web_token": "<token>" }`. Local-only: the presence
/// and validity of the file is the first-run signal (`hasLocalCredentials`), and `refresh()` re-reads
/// it so a rotated token is picked up on the next cycle.
struct LLMCenterAuthStore: Sendable {
    var files: TextFileAccessing
    var configPath: String

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        configPath: String? = nil
    ) {
        self.files = files
        self.configPath = configPath ?? Self.defaultConfigPath()
    }

    static func defaultConfigPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("llmctl/config.json").path
    }

    /// The signed-in auth, or `nil` when the user has not logged in. A present file that can't be read
    /// or parsed throws `credentialsUnreadable` so broken storage is never mistaken for logout; an
    /// absent file is the normal "not logged in" `nil`.
    func loadAuth() throws -> LLMCenterAuth? {
        let text: String?
        do {
            text = try files.readTextIfPresent(configPath)
        } catch {
            throw LLMCenterAuthError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw LLMCenterAuthError.credentialsUnreadable(detail: "config.json is not valid JSON")
        }
        guard let api = (object["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let webToken = (object["web_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return nil }
        return LLMCenterAuth(apiBaseURL: api, webToken: webToken)
    }
}