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
    case saveFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to LLM Center. Run `llmctl auth login` to sign in, then refresh."
        case .credentialsUnreadable:
            return "Couldn't read the LLM Center login. Check ~/Library/Application Support/llmctl/config.json, then refresh."
        case .saveFailed:
            return "Couldn't save the LLM Center login to disk. Check the file's permissions, then try again."
        }
    }
}

/// Reads `~/Library/Application Support/llmctl/config.json` — the file `llmctl auth login` writes on
/// Darwin — which holds `{ "api": "<base URL>", "web_token": "<token>" }`. The presence and validity of
/// the file is the first-run signal (`hasLocalCredentials`), and `refresh()` re-reads it so a rotated
/// token is picked up on the next cycle.
///
/// The store also *writes* the file, for one narrow case: `LLMCenterSignInService` completing an
/// in-app authorization. `llmctl auth login` short-circuits on any non-empty `web_token` without ever
/// validating it server-side, so an expired token leaves the CLI unable to re-login — the app finishing
/// the flow itself is the only way out. Writes preserve every key the CLI owns (see `save`).
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
        guard let object = try loadObject() else { return nil }
        guard let api = Self.text(object["api"]),
              let webToken = Self.text(object["web_token"])
        else { return nil }
        // A host the CLI recorded before it was retired is rewritten here rather than at each call
        // site, so every request — usage and sign-in alike — talks to the live deployment.
        return LLMCenterAuth(apiBaseURL: LLMCenterHost.migrated(api), webToken: webToken)
    }

    /// Just the API base URL, which `loadAuth()` can't supply once the token is gone: sign-in has to
    /// reach the same LLM Center deployment the CLI logged into, and that host is only recorded here.
    /// A machine that never ran `llmctl auth login` has no file and no host to talk to — hence `nil`,
    /// which the sign-in service surfaces as a first-run error rather than guessing a hostname.
    func loadAPIBaseURL() throws -> String? {
        guard let object = try loadObject() else { return nil }
        return Self.text(object["api"]).map(LLMCenterHost.migrated)
    }

    /// Writes a freshly authorized token back into the CLI's own config, so `llmctl` and OpenUsage keep
    /// sharing one login. Read-modify-write: every key already in the file survives untouched — the CLI
    /// also stores `access_key`, `model`, and `env`, and clobbering those would break it. `api` is only
    /// filled in when missing — or when the recorded host is one we know is retired, since leaving that
    /// in place would keep `llmctl` itself broken even though the app has recovered. `app_code` is only
    /// written when the authorization actually returned one, so a value the CLI set is never replaced
    /// with an invented one.
    func save(webToken: String, appCode: String?, api: String) throws {
        // A file we can't parse must not silently lose the CLI's other keys, but it also must not trap
        // the user: the whole point of in-app sign-in is recovering a broken login. So a corrupt file is
        // rebuilt from scratch and the loss is logged loudly rather than passed over.
        var object: [String: Any]
        do {
            object = try loadObject() ?? [:]
        } catch {
            AppLog.error(
                LogTag.auth("llmcenter"),
                "config.json is unparsable; rewriting it from scratch, other llmctl keys will be lost: \(error.localizedDescription)"
            )
            object = [:]
        }
        object["web_token"] = webToken
        if let recorded = Self.text(object["api"]) {
            // The one case where an existing value is replaced: a host confirmed dead. `api` reached
            // this method already migrated (sign-in read it through `loadAPIBaseURL`), so writing it
            // back repairs the file the CLI can no longer fix for itself.
            if LLMCenterHost.isRetired(recorded) {
                object["api"] = LLMCenterHost.migrated(recorded)
            }
        } else {
            object["api"] = api
        }
        if let appCode = appCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            object["app_code"] = appCode
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw LLMCenterAuthError.saveFailed(detail: "config.json could not be encoded as UTF-8")
            }
            // `LocalTextFileAccessor.writeText` publishes through a 0600 temp file + rename, so the
            // token is never briefly world-readable and a crash can't leave a truncated config.
            try files.writeText(configPath, text)
        } catch let error as LLMCenterAuthError {
            throw error
        } catch {
            throw LLMCenterAuthError.saveFailed(detail: error.localizedDescription)
        }
    }

    /// The parsed config, or `nil` when the file is absent. Shared by every accessor so a broken file is
    /// classified identically no matter which field the caller wanted.
    private func loadObject() throws -> [String: Any]? {
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
        return object
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
