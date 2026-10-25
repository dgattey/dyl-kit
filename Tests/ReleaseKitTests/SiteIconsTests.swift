import Foundation
import Testing

@testable import ReleaseKit

@Suite struct SiteIconsTests {
    /// The favicon: an ICO directory of PNG entries, which browsers read without an image library.
    @Test func icoIndexesEachPNG() {
        let small = Data([0x89, 0x50, 0x4E, 0x47, 1])
        let large = Data([0x89, 0x50, 0x4E, 0x47, 2, 3])
        let ico = [UInt8](SiteIcons.ico(pngs: [(16, small), (32, large)]))
        func u16(_ offset: Int) -> Int { Int(ico[offset]) | Int(ico[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

        #expect(Array(ico[0..<6]) == [0, 0, 1, 0, 2, 0])
        #expect(ico[6] == 16 && ico[22] == 32)
        #expect(u16(10) == 1 && u16(12) == 32)
        #expect(u32(14) == small.count && u32(18) == 38)
        #expect(u32(30) == large.count && u32(34) == 38 + small.count)
        #expect(Array(ico[38...]) == [UInt8](small + large))
    }

    @Test func namesAreUnique() {
        let names = SiteIcons.all.map(\.name)
        #expect(Set(names).count == names.count, "\(names)")
    }

    /// Other sites can embed these two paths, sizes and sources.
    @Test func keepsTheExternalContract() throws {
        let icon = try #require(SiteIcons.all.first { $0.name == "icon.png" })
        let touch = try #require(SiteIcons.all.first { $0.name == "apple-touch-icon.png" })
        #expect(icon.format == .png(pixels: 1024))
        #expect(touch.source == .fullBleedIOS)
        #expect(touch.format == .png(pixels: 180))
    }
}
