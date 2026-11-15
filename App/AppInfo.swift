import Foundation

/// The installed build, e.g. "0.5.0 (12) · ab3abbc", shown on a new chat until a gateway is added. CI
/// stamps the run number and the commit into Info.plist, so the app on the phone can be matched with its release.
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        guard let commit = info?["TermAICommit"] as? String, !commit.isEmpty else { return "\(short) (\(build))" }
        return "\(short) (\(build)) · \(commit)"
    }
}
