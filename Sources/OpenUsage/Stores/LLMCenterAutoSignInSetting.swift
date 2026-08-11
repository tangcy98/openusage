import Foundation

/// Whether OpenUsage opens the browser by itself when the saved LLM Center login turns out to be expired.
/// Off by default: opening a browser window is an outward-facing action, and the refresh that discovers
/// the expiry can happen while the user is doing something else. With it off, the LLM Center card still
/// offers a Sign In button — the toggle only decides whether the app takes the first step unprompted.
/// The switch sits in Settings → General and only appears when LLM Center is enabled.
enum LLMCenterAutoSignInSetting {
    static let key = "llmCenterAutoSignIn"
}
