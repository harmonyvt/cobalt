import Foundation

/// Randomly generated capybara-themed titles for uploaded files, so uploads go straight up
/// without prompting the owner to type a filename every time.
public enum CapybaraUploadNames {
    private static let adjectives: [String] = [
        "unbothered",
        "tax-evading",
        "certified",
        "suspiciously chill",
        "sleepy",
        "dramatic",
        "distinguished",
        "chaotic neutral",
        "professionally relaxed",
        "emotionally unavailable",
        "financially irresponsible",
        "deeply philosophical",
        "midnight snack",
        "low-battery",
        "politely rotund",
        "unsupervised",
        "quantum-napping",
        "freelance",
        "locally sourced",
        "illegally cozy",
        "stealth-mode",
        "dangerously chill",
        "aerodynamic",
        "turbo-chill",
        "four-wheel-drive",
        "limited-edition",
        "unlicensed",
        "overdressed",
        "wifi-stealing",
        "unapologetically round",
        "slightly toasted",
        "artisanal",
        "high-definition",
        "bluetooth-enabled",
        "maximum-cozy",
        "chronically chill",
        "mildly damp",
        "cosmic",
        "velvet-snouted",
        "extra-crispy",
        "horizontally spinning",
        "part-time",
        "tactical",
        "vintage",
        "deluxe",
        "organic",
        "premium",
        "mysteriously damp",
    ]

    private static let nouns: [String] = [
        "capybara",
        "capy",
        "yuzu capy",
        "hot spring capy",
        "onsen capybara",
        "tangerine capy",
        "melon capy",
        "swamp loaf",
        "citrus loaf",
        "guinea big",
        "coconut dog",
        "water pig",
        "river potato",
        "puddle capy",
        "jacuzzi capy",
        "capy loaf",
    ]

    private static let roles: [String] = [
        "ceo of vibes",
        "chief snack officer",
        "doctor of napping",
        "professor of chill",
        "mayor of swamp town",
        "duke of yuzu",
        "captain hot spring",
        "senior vibe engineer",
        "intern of the month",
        "lord of the puddles",
        "manager of snacks",
        "supreme court",
        "grand wizard",
        "minister of naps",
        "head of citrus",
        "director of lounging",
        "ambassador of chill",
        "king of the tub",
        "inspector",
        "detective",
        "emperor of melons",
        "chairperson of vibes",
    ]

    private static let roleSuffixes: [String] = [
        "capy",
        "capybara",
    ]

    private static let specialTitles: [String] = [
        "baron von capybara",
        "agent 00-capy",
        "sir yuzu the capybara",
        "capybara esquire",
        "the honorable capy",
        "dj yuzu capy",
    ]

    private static let activitySubjects: [String] = [
        "capy",
        "capybara",
        "lil capy",
    ]

    private static let activities: [String] = [
        "balancing three oranges",
        "dodging responsibilities",
        "vibing in the hot tub",
        "contemplating a melon",
        "committing mild tax fraud",
        "buffering at 2 percent",
        "ignoring all emails",
        "floating in soup mode",
        "stealing your charger",
        "on a tiny skateboard",
        "winning a staring contest",
        "snoozing on a pelican",
        "plotting a power nap",
        "reviewing your snacks",
        "declining the meeting",
        "living rent free",
        "soaking with yuzu",
        "munching forbidden grass",
        "judging you quietly",
        "pulling up to the party",
        "running on two braincells",
        "filing for snackruptcy",
        "ordering iced matcha",
        "taking a personal day",
        "forgetting the wifi password",
        "staring into the void",
        "skipping leg day",
        "vibing in airplane mode",
        "avoiding small talk",
        "clocking out early",
    ]

    /// Every possible name this generator can produce (used by tests to guarantee every combo
    /// obeys `MediaTitle.clean` and fits comfortably in Hark notification labels).
    static var allCandidates: [String] {
        var out: [String] = []
        out.reserveCapacity(adjectives.count * nouns.count + roles.count * roleSuffixes.count + specialTitles.count + activitySubjects.count * activities.count)
        for adj in adjectives {
            for noun in nouns {
                out.append("\(adj) \(noun)")
            }
        }
        for role in roles {
            for suffix in roleSuffixes {
                out.append("\(role) \(suffix)")
            }
        }
        out.append(contentsOf: specialTitles)
        for subject in activitySubjects {
            for activity in activities {
                out.append("\(subject) \(activity)")
            }
        }
        return out
    }

    /// Picks a funny capybara-themed upload title.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// Deterministic overload for tests.
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let roll = Int.random(in: 0..<100, using: &generator)
        if roll < 55 {
            let adj = adjectives[Int.random(in: 0..<adjectives.count, using: &generator)]
            let noun = nouns[Int.random(in: 0..<nouns.count, using: &generator)]
            return "\(adj) \(noun)"
        } else if roll < 75 {
            let totalRoles = roles.count * roleSuffixes.count + specialTitles.count
            let pick = Int.random(in: 0..<totalRoles, using: &generator)
            if pick < specialTitles.count {
                return specialTitles[pick]
            }
            let idx = pick - specialTitles.count
            let role = roles[idx / roleSuffixes.count]
            let suffix = roleSuffixes[idx % roleSuffixes.count]
            return "\(role) \(suffix)"
        } else {
            let subject = activitySubjects[Int.random(in: 0..<activitySubjects.count, using: &generator)]
            let activity = activities[Int.random(in: 0..<activities.count, using: &generator)]
            return "\(subject) \(activity)"
        }
    }
}
