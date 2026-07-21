import Foundation

/// One shared access-mode resolution rule used by every provider: OAuth wins
/// over "needs sign in", which wins over API key. `hasAPIKeyLikeAccess`
/// documents detection but never creates a third UI mode.
enum AccessModeResolver {
    static func resolve(
        oauth: OAuthAccess?,
        oauthNeedsSignIn: AccountCacheKey?,
        hasAPIKeyLikeAccess: Bool
    ) -> ResolvedProviderAccess {
        if let oauth = oauth {
            return .oauth(oauth)
        }
        if let oauthNeedsSignIn = oauthNeedsSignIn {
            return .oauthNeedsSignIn(accountKey: oauthNeedsSignIn)
        }
        if hasAPIKeyLikeAccess {
            return .apiKey
        }
        // No OAuth, no sign-in-needed marker, no API key detected. Default to
        // prompting for sign-in so the UI can drive a re-auth flow.
        return .oauthNeedsSignIn(accountKey: nil)
    }
}
