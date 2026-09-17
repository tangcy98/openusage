import Foundation

/// How long OpenUsage waits after discovering an expired LLMCenter login before opening the browser
/// automatically. `never` (the default) means the app never opens the browser by itself — the LLMCenter
/// card's Sign In button is always manual. Other intervals start a timer on the first expired-login
/// discovery; if the login is still expired when the timer fires, the app opens the browser once.
/// The setting sits in Settings → General and only appears when LLMCenter is enabled.
enum LLMCenterAutoSignInInterval: String, CaseIterable, Sendable {
    case immediate = "0min"
    case fiveMin = "5min"
    case fifteenMin = "15min"
    case thirtyMin = "30min"
    case oneHour = "1h"
    case twoHours = "2h"
    case fourHours = "4h"
    case twentyFourHours = "24h"
    case never = "never"

    var seconds: TimeInterval? {
        switch self {
        case .immediate: return 0
        case .fiveMin: return 300
        case .fifteenMin: return 900
        case .thirtyMin: return 1800
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .fourHours: return 14400
        case .twentyFourHours: return 86400
        case .never: return nil
        }
    }

    var displayName: String {
        switch self {
        case .immediate: return "Immediately"
        case .fiveMin: return "5 minutes"
        case .fifteenMin: return "15 minutes"
        case .thirtyMin: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        case .twentyFourHours: return "24 hours"
        case .never: return "Never"
        }
    }
}

enum LLMCenterAutoSignInSetting {
    static let key = "llmCenterAutoSignIn"
    static let defaultValue: LLMCenterAutoSignInInterval = .never
}
