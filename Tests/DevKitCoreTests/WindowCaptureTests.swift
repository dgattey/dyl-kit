import Testing

@testable import DevKitCore

@Suite struct WindowCaptureTests {
    private typealias Window = WindowCapture.ListedWindow

    /// A full-screen app had focus, so the background launch put the window on the desktop Space.
    @Test func aWindowOnAnotherSpaceIsCaptured() {
        let offSpace = Window(id: 10029, onScreen: false, shown: true, area: 1280 * 840)
        #expect(WindowCapture.mainWindow(in: [offSpace]) == 10029)
    }

    @Test func aWindowThatWasNeverShownIsNotAWindow() {
        let unshown = Window(id: 52, onScreen: false, shown: false, area: 1280 * 840)
        #expect(WindowCapture.mainWindow(in: [unshown]) == nil)
    }

    /// A closed window stays in the list at its old size, beside the one the reopen made.
    @Test func aReopenedWindowBeatsTheClosedOne() {
        let closed = Window(id: 36, onScreen: false, shown: false, area: 640 * 420)
        let reopened = Window(id: 51, onScreen: false, shown: true, area: 640 * 420)
        #expect(WindowCapture.mainWindow(in: [closed, reopened]) == 51)
    }

    @Test func onScreenBeatsALargerWindowOnAnotherSpace() {
        let offSpace = Window(id: 1, onScreen: false, shown: true, area: 2000 * 1000)
        let onScreen = Window(id: 2, onScreen: true, shown: true, area: 640 * 420)
        #expect(WindowCapture.mainWindow(in: [offSpace, onScreen]) == 2)
    }

    @Test func aWindowThatsGoneIsSaidPlainly() {
        #expect(WindowCapture.unreadable(.max).message.contains("closed"))
        #expect(!WindowCapture.notShown(7681).message.contains("Space"))
    }

    /// Without SkyLight's ordered-in check, a window on another Space looks the same as one that was never shown.
    @Test func skyLightTellsWindowsOnAnotherSpaceApart() {
        #expect(SkyLight.available)
    }
}
