import DylCore
import DylTestSupport
import Foundation
import SwiftUI
import Testing

struct SupportFolderTests {
    @Test func scopedFolderIsFreshAndRemovedAfterwards() async throws {
        let outside = AppDirectories.support
        let used = await AppDirectories.withTemporarySupportFolder { folder in
            #expect(AppDirectories.support == folder)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            return folder
        }
        #expect(AppDirectories.support == outside)
        #expect(!FileManager.default.fileExists(atPath: used.path))
    }

    @Test @MainActor func viewInspectorIsReExported() throws {
        let text = try Text("Hello").inspect().text().string()
        #expect(text == "Hello")
    }
}
