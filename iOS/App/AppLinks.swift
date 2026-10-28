import Foundation

/// The URLs the app shows, derived only from the Info.plist keys the xcconfig writes (§1.5: nothing
/// else in the codebase hard-codes a name or a URL).
enum AppLinks {
    static var website: URL? { url(forInfoKey: "TGWebsiteURL") }
    static var repository: URL? { url(forInfoKey: "TGRepoURL") }
    /// §1.5 "Mac download page": the newest GitHub release of Trackglass for Mac.
    static var macDownload: URL? { repository?.appendingPathComponent("releases").appendingPathComponent("latest") }
    /// §5.1 About: the same address as the App Store privacy policy (App Review 5.1.1).
    static var privacyPolicy: URL? { website?.appendingPathComponent("privacy.html") }
    static var support: URL? { website?.appendingPathComponent("support.html") }

    static func url(forInfoKey key: String, bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
