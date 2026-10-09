import Foundation

/// Reads the subscription name from `oauthAccount` in `~/.claude.json`.
/// The organization type identifies the plan; the rate-limit tier can also
/// distinguish Max 5× from Max 20×, but does not record a token allowance.
enum PlanReader {
    static func claudeCodePlan() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let tier = (account["organizationRateLimitTier"] as? String)
            ?? (account["userRateLimitTier"] as? String)
        let tierName = tier.flatMap(displayName)
        if let organization = account["organizationType"] as? String,
           let plan = displayName(for: organization) {
            if plan == "Max", tierName == "Max 5×" || tierName == "Max 20×" {
                return tierName
            }
            return plan
        }
        return tierName
    }

    /// `default_claude_max_5x` → `Max 5×`.
    static func displayName(for tier: String) -> String? {
        let name = tier
            .replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
        switch name {
        case "max_5x": return "Max 5×"
        case "max_20x": return "Max 20×"
        case "pro": return "Pro"
        case "prolite": return "Pro 5×"
        case "free": return "Free"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "ai": return nil
        default:
            guard !name.isEmpty else { return nil }
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
