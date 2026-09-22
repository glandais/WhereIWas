import Foundation

/// Every external URL the app can open, in one place. Each one leaves the app
/// for Safari or the App Store: none is fetched by the app itself.
///
/// No donation or tip link belongs here (guideline 3.1.1) — see `CLAUDE.md`,
/// "Held back for 1.0.1".
enum AppLinks {
    static let website = URL(string: "https://glandais.github.io/WhereIWas/")!
    static let support = URL(string: "https://glandais.github.io/WhereIWas/support/")!
    static let privacy = URL(string: "https://glandais.github.io/WhereIWas/privacy/")!
    static let sourceCode = URL(string: "https://github.com/glandais/WhereIWas")!
    static let writeReview = URL(string: "https://apps.apple.com/app/id6808349924?action=write-review")!
    static let developerApps = URL(string: "https://apps.apple.com/developer/id1891310404")!
}
