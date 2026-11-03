import Foundation

/// rushz: lets the host app attach a signed-in session (cookies + SAPISIDHASH) to InnerTube requests.
/// The provider is asked for every request URL and must return headers only for hosts it trusts.
public enum YouTubeAuth {
    nonisolated(unsafe) public static var headerProvider: (@Sendable (URL) async -> [String: String])?
}
