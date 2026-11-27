import Foundation
import Testing
@testable import CobaltKit

@Suite struct StrataLayoutTests {
    private func calendarUTC() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendarUTC().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func media(id: String, bytes: Int64, at createdAt: Date, extraWebpBytes: Int64 = 0) -> StoredMedia {
        let orig = StoredVideo(
            id: "\(id)-orig", kind: .original, fileURL: nil, posterURL: nil,
            name: "\(id).mp4", duration: 10, width: 720, height: 1280, bytes: bytes,
            sessionID: nil, link: nil, remoteURL: nil, createdAt: createdAt, mediaID: id)
        var webps: [StoredVideo] = []
        if extraWebpBytes > 0 {
            webps.append(StoredVideo(
                id: "\(id)-webp", kind: .webp, fileURL: nil, posterURL: nil,
                name: "\(id).webp", duration: 10, width: 480, height: 854, bytes: extraWebpBytes,
                sessionID: nil, link: nil, remoteURL: nil, createdAt: createdAt.addingTimeInterval(60), mediaID: id))
        }
        return StoredMedia(id: id, original: orig, webps: webps)!
    }

    @Test func emptyMediaProducesEmptyColumn() {
        let col = StrataLayout.build(from: [], now: date(2026, 11, 27), calendar: calendarUTC())
        #expect(col.isEmpty)
        #expect(col.totalBytes == 0)
        #expect(col.mediaCount == 0)
        #expect(col.maxLayerBytes == 0)
    }

    @Test func bucketsChronologicallyWithCumulativeRulerOffsets() {
        let cal = calendarUTC()
        let now = date(2026, 11, 27, hour: 15)
        let items = [
            media(id: "t1", bytes: 10_000_000, at: date(2026, 11, 27, hour: 14)),
            media(id: "t2", bytes: 8_000_000, at: date(2026, 11, 27, hour: 9), extraWebpBytes: 2_000_000),
            media(id: "y1", bytes: 28_000_000, at: date(2026, 11, 26, hour: 18)),
            media(id: "w1", bytes: 40_000_000, at: date(2026, 11, 22, hour: 12)),
            media(id: "m1", bytes: 32_000_000, at: date(2026, 10, 10, hour: 12)),
            media(id: "o1", bytes: 50_000_000, at: date(2025, 8, 4, hour: 12)),
        ]

        let col = StrataLayout.build(from: items.reversed(), now: now, calendar: cal)
        #expect(col.mediaCount == 6)
        #expect(col.layers.map(\.bucket) == [
            .today,
            .yesterday,
            .thisWeek,
            .month(year: 2026, month: 10),
            .older,
        ])
        #expect(col.layers.map(\.depth) == [0, 1, 2, 3, 4])
        #expect(col.layers.map(\.bytes) == [20_000_000, 28_000_000, 40_000_000, 32_000_000, 50_000_000])
        #expect(col.layers.map(\.cumulativeStartBytes) == [0, 20_000_000, 48_000_000, 88_000_000, 120_000_000])
        #expect(col.layers.map(\.cumulativeEndBytes) == [20_000_000, 48_000_000, 88_000_000, 120_000_000, 170_000_000])
        #expect(col.totalBytes == 170_000_000)
        #expect(col.maxLayerBytes == 50_000_000)
    }

    @Test func layerHeightScalesProportionallyAndRespectsBounds() {
        let small = StrataLayout.layerHeight(bytes: 10_000_000, maxLayerBytes: 100_000_000)
        let big = StrataLayout.layerHeight(bytes: 100_000_000, maxLayerBytes: 100_000_000)
        #expect(small >= 92)
        #expect(big > small)
        #expect(big <= 176)

        // Multi-gigabyte layer compresses smoothly instead of overflowing maxHeight.
        let huge = StrataLayout.layerHeight(bytes: 4_000_000_000, maxLayerBytes: 4_000_000_000)
        let halfHuge = StrataLayout.layerHeight(bytes: 2_000_000_000, maxLayerBytes: 4_000_000_000)
        #expect(huge == 176)
        #expect(halfHuge > 92 && halfHuge < huge)
    }

    @Test func megabyteTicksStayCompact() {
        #expect(StrataLayout.megabyteTick(for: 0) == "0")
        #expect(StrataLayout.megabyteTick(for: 400_000) == "<1")
        #expect(StrataLayout.megabyteTick(for: 18_400_000) == "18")
        #expect(StrataLayout.megabyteTick(for: 164_600_000) == "165")
        #expect(StrataLayout.megabyteTick(for: 1_450_000_000) == "1.5g")
    }
}
