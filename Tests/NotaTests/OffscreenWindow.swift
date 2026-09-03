import AppKit

extension NSWindow {
    /// Orders the window front the way a test needs — `isVisible` true, the
    /// window server laying it out, key for the find bar and the tracking
    /// loops — without a single frame of it reaching the screen. The suite
    /// runs while the app is being worked on, and a window that flashes up
    /// on every run is not a window anybody asked to see.
    ///
    /// Two belts: the frame is put well outside every display, and the
    /// window is made fully transparent in case AppKit ever nudges an
    /// off-screen frame back on. Events synthesised at a window's own
    /// coordinates are routed by window number, so neither changes what a
    /// test can do to it.
    func makeKeyAndOrderFrontOffscreen() {
        alphaValue = 0
        setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        makeKeyAndOrderFront(nil)
    }
}
