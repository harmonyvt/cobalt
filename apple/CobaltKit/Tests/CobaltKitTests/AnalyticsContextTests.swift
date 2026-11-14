import Foundation
import Testing
@testable import CobaltKit

// APP-API-CONTRACT 58: the PostHog project from /capabilities, and the headers the app's own requests carry.
@Suite(.serialized)
struct AnalyticsContextTests {
    private func caps(_ extra: String) throws -> Capabilities {
        let json = #"{"server":"cobalt-cloudflare","features":{"library":true},"key":"valid"\#(extra)}"#
        return try #require(HTTPCobaltClient.parseForkCapabilities(Data(json.utf8)))
    }

    @Test func theProjectIsReadAndAbsentOrBrokenMeansNone() throws {
        let on = try caps(#","posthog":{"token":"phc_abc","host":"https://us.i.posthog.com"}"#)
        #expect(on.postHog == PostHogProject(token: "phc_abc", host: URL(string: "https://us.i.posthog.com")!))
        #expect(try caps("").postHog == nil)
        #expect(try caps(#","posthog":{"token":"","host":"https://us.i.posthog.com"}"#).postHog == nil)
        #expect(try caps(#","posthog":{"token":"phc_abc","host":"http://plain.example"}"#).postHog == nil)
        #expect(Capabilities.unknown.postHog == nil)
    }

    @Test func theProjectSurvivesBeingRemembered() throws {
        let on = try caps(#","posthog":{"token":"phc_abc","host":"https://us.i.posthog.com"}"#)
        let back = try JSONDecoder().decode(Capabilities.self, from: JSONEncoder().encode(on))
        #expect(back.postHog == on.postHog)
    }

    @Test func onlyTheClientIsSentUntilTheSDKRuns() {
        AnalyticsContext.setSessionProvider(nil)
        let off = AnalyticsContext.headers(install: { "install" })
        #expect(off.map(\.0) == [AnalyticsContext.clientHeader])

        let session = "019A8FF2-7E99-7000-8000-E0457F33A638"
        AnalyticsContext.setSessionProvider { session }
        defer { AnalyticsContext.setSessionProvider(nil) }
        let on = Dictionary(uniqueKeysWithValues: AnalyticsContext.headers(install: { "inst" }))
        #expect(on[AnalyticsContext.installHeader] == "inst")
        #expect(on[AnalyticsContext.sessionHeader] == session.lowercased())

        AnalyticsContext.setSessionProvider { "not-a-uuid" }
        #expect(AnalyticsContext.headers(install: { "inst" }).map(\.0).contains(AnalyticsContext.sessionHeader) == false)
    }
}
