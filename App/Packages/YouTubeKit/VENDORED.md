Vendored from https://github.com/alexeichhorn/YouTubeKit (MIT, see LICENSE)
Upstream commit: 7f75a2299dc329c0b7855afb25d47663a02855cb (2026-10-31)
This copy is ours: edit it directly. Local changes: Package.swift (no test target); InnerTube.swift (log YouTube's reply per client).
Client definitions are checked against yt-dlp's current ones.
Local changes (2): Auth.swift (YouTubeAuth.headerProvider) + InnerTube.swift callAPI attaches the host app's signed-in headers.
Local changes (3): Errors.swift + YouTube.swift: YouTubeKitError.loginRequired is thrown when every client hits the bot gate.
