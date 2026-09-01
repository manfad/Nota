import Foundation

/// What `:help` opens.
///
/// It is generated from the table below rather than written out as prose, so
/// it can only ever list keys that are really here: adding a command means
/// adding a line to `sections`, and the help says so from then on. Plain text,
/// like everything else in Jot.
enum VimHelp {
    static let title = "Help"

    struct Entry {
        var keys: String
        var summary: String

        init(_ keys: String, _ summary: String) {
            self.keys = keys
            self.summary = summary
        }
    }

    struct Section {
        var name: String
        var entries: [Entry]

        init(_ name: String, _ entries: [Entry]) {
            self.name = name
            self.entries = entries
        }
    }

    static let sections: [Section] = [
        Section("Modes", [
            Entry("Esc  ⌃[  ⌃C", "back to normal mode (there is no jk)"),
            Entry("i I a A", "insert before, at the first non-blank, after, at the end"),
            Entry("o O", "open a line below or above"),
            Entry("R", "replace mode"),
            Entry("v V", "visual by characters, by lines"),
            Entry(":", "the command line, in the footer"),
            Entry("⌘…", "every menu shortcut works in every mode"),
        ]),
        Section("Motions", [
            Entry("h j k l", "left, down, up, right (arrows too)"),
            Entry("w W b B e E", "words; the capitals count blanks only"),
            Entry("ge gE", "back to the end of the previous word"),
            Entry("0 ^ $", "start of line, first non-blank, end of line"),
            Entry("| _ + -", "column, this line, the next, the previous"),
            Entry("gg G", "first line, last line — or the count's line"),
            Entry("{ } ( )", "paragraphs, sentences"),
            Entry("%", "the matching bracket"),
            Entry("f F t T ; ,", "find a character on the line, and repeat it"),
            Entry("H M L", "top, middle and bottom of the screen"),
            Entry("3w  d2j", "counts go before, or between, the keys"),
        ]),
        Section("Scrolling", [
            Entry("⌃D ⌃U", "half a page down, up"),
            Entry("⌃F ⌃B", "a page down, up"),
            Entry("⌃E ⌃Y", "one line, leaving the caret where it is"),
            Entry("zz zt zb", "this line to the middle, top, bottom"),
        ]),
        Section("Operators", [
            Entry("d c y", "delete, change, yank a motion or object"),
            Entry("> < =", "indent, dedent, re-indent whole lines"),
            Entry("g~ gu gU", "toggle case, lowercase, uppercase"),
            Entry("dd cc yy >> << ==", "the doubled form takes whole lines"),
            Entry("guu gUU g~~", "and so do these"),
        ]),
        Section("Text objects", [
            Entry("iw aw iW aW", "a word, with or without its blanks"),
            Entry("is as ip ap", "a sentence, a paragraph"),
            Entry("i\" a\" i' a' i` a`", "quoted text"),
            Entry("i( i[ i{ i<", "the brackets and their pairs"),
            Entry("it at", "an XML or HTML tag"),
        ]),
        Section("Editing", [
            Entry("x X", "delete forward, backward"),
            Entry("p P", "put after, before — linewise if it was taken so"),
            Entry("r ~", "replace one character, flip its case"),
            Entry("J", "join lines"),
            Entry("⌃A ⌃X", "add to, subtract from the number on the line"),
            Entry("u ⌃R", "undo, redo"),
            Entry(".", "repeat the last change (3. repeats it three times)"),
        ]),
        Section("Visual mode", [
            Entry("v V gv", "start, by lines, reselect the last one"),
            Entry("o", "swap which end the motions move"),
            Entry("d c y > < = ~ u U", "act on the selection"),
            Entry("Y D X C S R", "the same by whole lines"),
            Entry("J p P r", "join, put over, replace every character"),
            Entry(":", "opens the command line with '<,'> already there"),
        ]),
        Section("Registers", [
            Entry("\"a … \"z", "name a register; \"A appends to \"a"),
            Entry("\"0", "the last yank"),
            Entry("\"1 … \"9", "the last nine line-sized deletes"),
            Entry("\"- \"_", "the small delete, the black hole"),
            Entry("\"+ \"*", "the system pasteboard, which is also unnamed"),
        ]),
        Section("Marks and macros", [
            Entry("ma  'a  `a", "set a mark, jump to its line, to its character"),
            Entry("'' '. '^ '< '>", "the jump, the change, insert, the selection"),
            Entry("qa … q", "record into a register"),
            Entry("@a @@", "play it back, play the last one again"),
        ]),
        Section("Insert mode", [
            Entry("⌃W ⌃U", "delete the word before, back to the line's start"),
            Entry("⌃T ⌃D", "indent, dedent this line"),
        ]),
        Section("Searching", [
            Entry("/ ?", "open the find bar; ? searches backward"),
            Entry("n N", "the next match, the one the other way"),
            Entry("* #", "search for the word under the caret"),
            Entry(":noh", "put the find bar away"),
        ]),
        Section("Tabs", [
            Entry("gt gT", "the next tab, the previous one"),
            Entry(":tabnew", "a new tab"),
            Entry(":tabn :tabp", "next, previous (:bn and :bp too)"),
        ]),
        Section("Ex commands", [
            Entry(":w [name]", "write; a name saves into the last-used folder"),
            Entry(":q  :q!  :wq  :x", "close the tab, discarding, writing first"),
            Entry(":e path", "open a file in a new tab"),
            Entry(":15", "go to line 15"),
            Entry(":s/old/new/", "substitute on this line; g all, i any case"),
            Entry(":%s/old/new/g", "the whole note"),
            Entry(":d [reg]  :y [reg]", "delete, yank the range's lines"),
            Entry(":j", "join the range's lines"),
            Entry(":m {addr}  :t {addr}", "move, copy them below an address"),
            Entry(":sort [!iun]", "sort; ! reverses, i any case, u unique, n numeric"),
            Entry(":> :<", "indent, dedent; :>> shifts twice"),
            Entry(":set cursorline", "a quiet band under the caret's line"),
            Entry(":help :reg :marks", "these tables, in a read-only tab"),
        ]),
        Section("Ranges", [
            Entry(":10,20d", "lines 10 to 20"),
            Entry(":%s/…", "the whole note"),
            Entry(":.,+3>", "from this line, three further on"),
            Entry(":'a,'bd", "between two marks"),
            Entry(":'<,'>sort", "the last visual selection"),
            Entry(":$", "the last line"),
        ]),
    ]

    /// The tab's text: one aligned block per section, keys in the first
    /// column, what they do in the second.
    static var text: String {
        var lines = [
            "Jot — vim mode",
            "",
            "Every key and command Jot's vim mode understands. This tab is",
            "read-only; :q closes it.",
        ]
        for section in sections {
            lines.append("")
            lines.append(section.name.uppercased())
            let width = section.entries.map(\.keys.count).max() ?? 0
            for entry in section.entries {
                let keys = entry.keys.padding(
                    toLength: max(width, entry.keys.count), withPad: " ", startingAt: 0
                )
                lines.append("  \(keys)   \(entry.summary)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
