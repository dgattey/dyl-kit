import Foundation
import Testing

@testable import DevKitCore

@Suite struct SiteIconsTests {
    /// Photos' favicon: an ICO directory of PNG entries, which browsers read without an image library.
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

    /// actool never writes a 180 px iPhone icon, so apple-icon.png comes from the largest one it did write.
    @Test func picksTheLargestLooseIcon() throws {
        #expect(SiteIcons.pixelSize("AppIcon60x60@2x.png") == 120)
        #expect(SiteIcons.pixelSize("AppIcon76x76@2x~ipad.png") == 152)
        #expect(SiteIcons.pixelSize("AppIcon83.5x83.5@2x~ipad.png") == 167)
        #expect(SiteIcons.pixelSize("Assets.car") == 0)

        let directory = FileManager.default.temporaryDirectory.appending(path: "site-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png", "Assets.car"] {
            try Data().write(to: directory.appending(path: name))
        }
        #expect(SiteIcons.largestFullBleedPNG(in: directory)?.lastPathComponent == "AppIcon76x76@2x~ipad.png")
    }
}
