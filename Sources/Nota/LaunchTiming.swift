import AppKit
import Darwin

/// Where the launch's time goes, phase by phase, for the one question
/// "why does the Dock icon bounce": run the binary with
/// `NOTA_LAUNCH_TIMING=1` in its environment and the report comes out on
/// stderr a second after launch, one line per mark, each with the time since
/// the process started and the time since the mark before it.
///
/// `open` does not pass the shell's environment on, so the run is the binary
/// itself: `NOTA_LAUNCH_TIMING=1 ./Nota.app/Contents/MacOS/Nota`.
///
/// Without the variable every `mark` is one `Bool` read and nothing else, so
/// the marks stay in the code. The first line, `exec`, is the kernel's own
/// start time for the process, so everything dyld and the Swift runtime do
/// before `main` is on the report too, as the gap to the `main` mark.
enum LaunchTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTA_LAUNCH_TIMING"] != nil

    private(set) static var marks: [(name: String, at: Double)] = []
    private static var reported = false

    static func mark(_ name: String) {
        guard isEnabled else { return }
        marks.append((name, CFAbsoluteTimeGetCurrent()))
    }

    /// Called once the launch method has done its work. The report waits a
    /// second so that the marks the run loop makes after it — the first turn,
    /// the window becoming key — are on it too.
    static func scheduleReport() {
        guard isEnabled, !reported else { return }
        reported = true
        DispatchQueue.main.async { mark("first run-loop turn") }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            mark("window key")
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
    }

    private static func report() {
        var lines = ["Nota launch timing (ms since exec · ms since previous mark)"]
        var all = marks
        if let started = processStart() { all.insert(("exec", started), at: 0) }
        guard let first = all.first else { return }
        var previous = first.at
        for mark in all {
            let sinceStart = (mark.at - first.at) * 1000
            let sincePrevious = (mark.at - previous) * 1000
            lines.append(String(format: "%8.1f  %+8.1f  %@", sinceStart, sincePrevious, mark.name))
            previous = mark.at
        }
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    /// The moment the kernel started this process, on the same clock as the
    /// marks (seconds since 2001).
    private static func processStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let unix = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return unix - kCFAbsoluteTimeIntervalSince1970
    }
}
