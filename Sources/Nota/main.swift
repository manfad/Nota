import AppKit

LaunchTiming.mark("main")
let app = NSApplication.shared
LaunchTiming.mark("NSApplication.shared")
let delegate = AppDelegate()
LaunchTiming.mark("AppDelegate()")
app.delegate = delegate
app.setActivationPolicy(.regular)
LaunchTiming.mark("activation policy set")
app.run()
