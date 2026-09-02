import Foundation

/// The tables `:reg` and `:marks` open.
///
/// Vim shows these in a pager; Nota has tabs, so they are read-only tabs — but
/// the layout is vim's, down to `^J` standing in for the line breaks inside a
/// register, so what you already know how to read still reads the same.
enum VimScratch {
    static let registersTitle = "Registers"
    static let marksTitle = "Marks"

    /// `:reg`. The unnamed register is the system pasteboard here, so it is
    /// passed in rather than read from the store.
    static func registers(
        _ registers: VimRegisters, unnamed: VimRegisters.Entry?
    ) -> String {
        var lines = ["Type Name Content"]
        if let unnamed {
            lines.append(row(name: "\"", entry: unnamed))
        }
        for register in registers.listing() {
            lines.append(row(name: String(register.name), entry: register.entry))
        }
        if lines.count == 1 { lines.append("  (no registers set)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func row(name: String, entry: VimRegisters.Entry) -> String {
        let type = entry.isLinewise ? "l" : "c"
        let label = "\"\(name)".padding(toLength: 4, withPad: " ", startingAt: 0)
        return "  \(type)  \(label) \(escaped(entry.text))"
    }

    /// A register is one string however many lines it holds, and vim shows
    /// the breaks inside it as `^J`.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "^J")
            .replacingOccurrences(of: "\t", with: "^I")
    }

    /// `:marks`. Columns are 0-based, the way vim counts them here.
    static func marks(_ marks: VimMarks, in text: NSString) -> String {
        var lines = ["mark line  col text"]
        for mark in marks.listing() {
            let location = min(max(0, mark.location), text.length)
            let position = TextStats.cursorPosition(in: text, at: location)
            let start = VimMotions.lineStart(text, at: location)
            let body = text.substring(
                with: NSRange(location: start, length: VimMotions.lineEnd(text, at: start) - start)
            )
            lines.append(
                " \(mark.name)"
                    + pad("\(position.line)", width: 7, trailing: false)
                    + pad("\(position.column - 1)", width: 5, trailing: false)
                    + " \(body)"
            )
        }
        if lines.count == 1 { lines.append(" (no marks set)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pad(_ value: String, width: Int, trailing: Bool) -> String {
        guard value.count < width else { return value }
        let padding = String(repeating: " ", count: width - value.count)
        return trailing ? value + padding : padding + value
    }
}
