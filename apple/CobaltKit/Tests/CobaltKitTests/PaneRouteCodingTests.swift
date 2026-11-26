import Foundation
import Testing
@testable import CobaltKit

// The route saved per scene (`@SceneStorage("pane")`): every item round-trips, the wire form is flat, and anything
// this build does not understand restores as nothing open instead of failing the scene.
@Suite struct PaneRouteCodingTests {
    static let everyItem: [PaneItem] = [
        .post("p1"), .peek("p2"), .selection, .save("job-1"), .link("set-1"), .collection("c1"), .emote("01H"),
        .emoteAddToSet("01J"), .reward("r1"), .poolVideo("v1"), .stream("ninja"),
        .dualStream(primary: "ninja", secondary: "shroud"), .booruPost(4821), .booruFilters,
        .swarm("sw1"), .name("n1"), .job("q1"),
    ]

    @Test func everyItemRoundTrips() throws {
        for item in Self.everyItem {
            let data = try JSONEncoder().encode(item)
            #expect(try JSONDecoder().decode(PaneItem.self, from: data) == item)
        }
        // and every kind word is distinct
        #expect(Set(Self.everyItem.map(\.kind)).count == Self.everyItem.count)
    }

    @Test func wireFormIsFlat() throws {
        func json(_ item: PaneItem) throws -> [String: AnyHashable] {
            let data = try JSONEncoder().encode(item)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        }
        #expect(try json(.post("abc")) == ["kind": "post", "id": "abc"])
        #expect(try json(.dualStream(primary: "a", secondary: "b")) == ["kind": "dualStream", "id": "a", "secondary": "b"])
        #expect(try json(.booruPost(7)) == ["kind": "booruPost", "n": 7])
        #expect(try json(.selection) == ["kind": "selection"])
    }

    @Test func routeRoundTrips() throws {
        for state in PaneState.allCases {
            let route = PaneRoute(item: .stream("x"), state: state, shelf: 2)
            #expect(PaneRoute.decoded(route.encoded()) == route)
        }
        #expect(PaneRoute.decoded(PaneRoute.hidden.encoded()) == .hidden)
    }

    @Test func aPeekIsNeverSaved() {
        let route = PaneRoute(item: .peek("p"), state: .screen, shelf: 1)
        #expect(PaneRoute.decoded(route.encoded()) == .hidden)
    }

    @Test func unknownOrBrokenDataRestoresNothing() {
        #expect(PaneRoute.decoded(nil) == nil)
        #expect(PaneRoute.decoded(Data("not json".utf8)) == nil)
        let unknownKind = Data(#"{"item":{"kind":"hologram","id":"x"},"state":"span","shelf":1}"#.utf8)
        #expect(PaneRoute.decoded(unknownKind) == .hidden)
        let unknownState = Data(#"{"item":{"kind":"post","id":"x"},"state":"floating","shelf":0}"#.utf8)
        #expect(PaneRoute.decoded(unknownState) == PaneRoute(item: .post("x"), state: .hidden, shelf: 0))
        let missingID = Data(#"{"item":{"kind":"post"},"state":"screen"}"#.utf8)
        #expect(PaneRoute.decoded(missingID) == .hidden)
        let negativeShelf = Data(#"{"item":{"kind":"link","id":"l"},"state":"screen","shelf":-4}"#.utf8)
        #expect(PaneRoute.decoded(negativeShelf) == PaneRoute(item: .link("l"), state: .screen, shelf: 0))
    }

    @Test func savedFromTheMachineSurvivesARelaunch() {
        var m = PaneMachine()
        m.open(.swarm("s"))
        m.span()
        m.setShelf(1)
        m.open(.peek("p"))                          // a finger was down when the app went away
        var relaunched = PaneMachine()
        relaunched.restore(PaneRoute.decoded(m.saved.encoded()) ?? .hidden)
        #expect(relaunched.route == PaneRoute(item: .swarm("s"), state: .span, shelf: 1))
    }
}
