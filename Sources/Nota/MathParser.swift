import AppKit

/// Which face a run of glyphs is set in. TeX's own rule, kept simple: Latin
/// letters lean, digits and operators stand up, and the `\math…` commands say
/// otherwise for the run they wrap.
enum MathFace {
    case italic
    case upright
    case bold
    case boldItalic
    case monospaced
}

/// What size a `\frac` asks its two halves to be, whatever style it landed in.
/// `\dfrac` and `\tfrac` are the two ways of overruling the surroundings.
enum MathSizeOverride {
    case inherit
    case display
    case text
}

/// A large operator. `\sum` is one glyph that grows in display and takes its
/// limits above and below; `\lim` is a word set upright that does the same.
struct MathOperator {
    let text: String
    let isWord: Bool
}

/// One node of a parsed formula.
///
/// The tree is TeX's own shape rather than Foundation's: a horizontal list of
/// atoms, some of which stack (a fraction, a radical, an operator with its
/// limits) and some of which wrap (a `\left…\right` pair). Nothing here knows
/// about points or fonts — that is `MathLayout`'s half of the work.
indirect enum MathNode {
    /// Glyphs that sit on one baseline in one face.
    case run(String, MathFace)
    /// Atoms in a row, on a shared baseline.
    case list([MathNode])
    /// A base with a superscript, a subscript or both, stacked at the same
    /// horizontal position.
    case scripts(base: MathNode?, sub: MathNode?, sup: MathNode?)
    /// `\frac` and, with `rule: false`, the inside of a `\binom`.
    case fraction(numerator: MathNode, denominator: MathNode, rule: Bool, size: MathSizeOverride)
    /// `\sqrt{x}` and `\sqrt[n]{x}`.
    case radical(index: MathNode?, radicand: MathNode)
    /// `\sum` `\int` `\lim` and the rest of the big ones.
    case bigOperator(MathOperator)
    /// `\left( … \right)`. A `nil` side is `\left.` — an invisible delimiter.
    case delimited(left: String?, right: String?, body: MathNode)
    /// A combining mark laid over what it accents.
    case accent(Character, MathNode)
    /// Blank room, measured in ems of the font it lands in. Negative for `\!`.
    case space(CGFloat)
    /// TeX the subset does not know, kept verbatim to be shown as itself.
    case raw(String)
}

/// Why a formula could not be read at all. Every one of these comes back to
/// the caller as a `nil` from `MathRenderer.layout`, which then shows the
/// source as a code span. An unknown command is never one of these.
enum MathParseError: Error {
    case empty
    case unbalancedBrace
    case unmatchedDelimiter
    case missingArgument
    case tooDeep
}

/// A TeX subset, read left to right into `MathNode`s.
///
/// Total by construction: every path through the loop moves the cursor on, so
/// no input can hang it, and the recursion carries a depth so no input can run
/// the stack out. What it refuses — an unbalanced brace, a `\left` with no
/// `\right`, a `\frac` short of an argument, nothing at all — it refuses by
/// throwing; everything else it renders, including the TeX it has never heard
/// of, which comes back as `.raw` to be shown as itself.
struct MathParser {

    /// How deep `{…}` and `\frac` may nest before the parser gives up. Deep
    /// enough for any formula anyone writes, shallow enough that a fuzzer
    /// cannot walk off the stack.
    static let maximumDepth = 64

    static func parse(_ tex: String) throws -> MathNode {
        var parser = MathParser(source: Array(tex))
        let nodes = try parser.parseList(until: .endOfInput, depth: 0)
        guard !nodes.isEmpty else { throw MathParseError.empty }
        return .list(nodes)
    }

    private let source: [Character]
    private var index = 0

    private init(source: [Character]) {
        self.source = source
    }

    /// What ends the list being read — and so what it means to run out of
    /// input in the middle of one.
    private enum Terminator {
        case endOfInput
        case brace
        case bracket
        case right
    }

    // MARK: - Lists and atoms

    private mutating func parseList(until terminator: Terminator, depth: Int) throws -> [MathNode] {
        guard depth <= MathParser.maximumDepth else { throw MathParseError.tooDeep }
        var nodes: [MathNode] = []
        while true {
            guard index < source.count else {
                switch terminator {
                case .endOfInput: return nodes
                case .right: throw MathParseError.unmatchedDelimiter
                case .brace, .bracket: throw MathParseError.unbalancedBrace
                }
            }
            let character = source[index]
            if character == "}" {
                guard terminator == .brace else { throw MathParseError.unbalancedBrace }
                index += 1
                return nodes
            }
            if character == "]", terminator == .bracket {
                index += 1
                return nodes
            }
            // A literal space in math is nothing at all — TeX's rule, and the
            // reason `\,` and friends exist.
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "^" || character == "_" {
                index += 1
                let argument = try parseArgument(depth: depth + 1)
                nodes.append(Self.attach(argument, superscript: character == "^", to: nodes.popLast()))
                continue
            }
            // `x'` is a superscript prime, the way it reads on paper.
            if character == "'" {
                index += 1
                nodes.append(Self.attach(.run("′", .upright), superscript: true, to: nodes.popLast()))
                continue
            }
            if character == "\\", let name = peekCommandName(), name == "right" {
                guard terminator == .right else { throw MathParseError.unmatchedDelimiter }
                index += 1 + name.count
                return nodes
            }
            nodes.append(try parseAtom(depth: depth))
        }
    }

    /// Puts a script on the atom before it, keeping any script that atom has
    /// already picked up so `x_i^2` stacks both at one place.
    private static func attach(_ script: MathNode, superscript: Bool, to base: MathNode?) -> MathNode {
        var target = base
        var sub: MathNode?
        var sup: MathNode?
        if case .scripts(let inner, let existingSub, let existingSup)? = target {
            target = inner
            sub = existingSub
            sup = existingSup
        }
        if superscript {
            sup = script
        } else {
            sub = script
        }
        return .scripts(base: target, sub: sub, sup: sup)
    }

    private mutating func parseAtom(depth: Int) throws -> MathNode {
        guard depth <= MathParser.maximumDepth else { throw MathParseError.tooDeep }
        guard index < source.count else { throw MathParseError.missingArgument }
        let character = source[index]
        if character == "{" {
            index += 1
            return .list(try parseList(until: .brace, depth: depth + 1))
        }
        if character == "\\" {
            return try parseCommand(depth: depth)
        }
        index += 1
        if character == "~" { return .space(0.333) }
        return .run(String(character), character.isLetter ? .italic : .upright)
    }

    /// One argument: a `{…}` group, a command, or the single character after
    /// the `^` in `x^2`.
    private mutating func parseArgument(depth: Int) throws -> MathNode {
        guard depth <= MathParser.maximumDepth else { throw MathParseError.tooDeep }
        while index < source.count, source[index].isWhitespace { index += 1 }
        guard index < source.count else { throw MathParseError.missingArgument }
        let character = source[index]
        guard character != "}", character != "^", character != "_" else {
            throw MathParseError.missingArgument
        }
        return try parseAtom(depth: depth)
    }

    // MARK: - Commands

    /// The name after a backslash without moving the cursor: the run of
    /// letters, or the single character of `\,` and `\{`.
    private func peekCommandName() -> String? {
        guard index < source.count, source[index] == "\\" else { return nil }
        var scan = index + 1
        guard scan < source.count else { return nil }
        if source[scan].isLetter {
            var name = ""
            while scan < source.count, source[scan].isLetter {
                name.append(source[scan])
                scan += 1
            }
            return name
        }
        return String(source[scan])
    }

    private mutating func parseCommand(depth: Int) throws -> MathNode {
        index += 1  // the backslash
        guard index < source.count else { return .raw("\\") }
        var name = ""
        if source[index].isLetter {
            while index < source.count, source[index].isLetter {
                name.append(source[index])
                index += 1
            }
        } else {
            name = String(source[index])
            index += 1
        }

        if name == "right" { throw MathParseError.unmatchedDelimiter }

        if let ems = MathTables.spacing[name] { return .space(ems) }
        if let symbol = MathTables.symbols[name] { return .run(symbol, .upright) }
        if let symbol = MathTables.bigOperators[name] {
            return .bigOperator(MathOperator(text: symbol, isWord: false))
        }
        if MathTables.limitWords.contains(name) {
            return .bigOperator(MathOperator(text: name, isWord: true))
        }
        if MathTables.functions.contains(name) {
            return .list([.run(name, .upright), .space(0.167)])
        }
        if let mark = MathTables.accents[name] {
            return .accent(mark, try parseArgument(depth: depth + 1))
        }

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = try parseArgument(depth: depth + 1)
            let denominator = try parseArgument(depth: depth + 1)
            let size: MathSizeOverride = name == "dfrac" || name == "cfrac"
                ? .display : (name == "tfrac" ? .text : .inherit)
            return .fraction(numerator: numerator, denominator: denominator, rule: true, size: size)
        case "binom", "dbinom", "tbinom":
            let top = try parseArgument(depth: depth + 1)
            let bottom = try parseArgument(depth: depth + 1)
            return .delimited(
                left: "(", right: ")",
                body: .fraction(numerator: top, denominator: bottom, rule: false, size: .inherit)
            )
        case "sqrt":
            var radicalIndex: MathNode?
            while index < source.count, source[index].isWhitespace { index += 1 }
            if index < source.count, source[index] == "[" {
                index += 1
                radicalIndex = .list(try parseList(until: .bracket, depth: depth + 1))
            }
            return .radical(index: radicalIndex, radicand: try parseArgument(depth: depth + 1))
        case "left":
            let left = try parseDelimiter()
            let body = try parseList(until: .right, depth: depth + 1)
            let right = try parseDelimiter()
            return .delimited(left: left, right: right, body: .list(body))
        case "text", "textrm", "mathrm", "operatorname", "mathsf":
            return .run(try parseRawArgument(), .upright)
        case "mathbf", "textbf", "bm", "boldsymbol":
            return .run(try parseRawArgument(), .bold)
        case "mathit", "textit":
            return .run(try parseRawArgument(), .italic)
        case "mathtt", "texttt":
            return .run(try parseRawArgument(), .monospaced)
        case "mathbb":
            return Self.mapped(try parseRawArgument(), through: MathTables.blackboard, fallback: .bold)
        case "mathcal", "mathscr":
            return Self.mapped(try parseRawArgument(), through: MathTables.script, fallback: .italic)
        case "begin":
            return .raw(readEnvironment())
        default:
            return .raw("\\" + name)
        }
    }

    /// The characters of an argument, verbatim — what `\text{a b}` needs, since
    /// its spaces are real and its letters are not maths.
    private mutating func parseRawArgument() throws -> String {
        while index < source.count, source[index].isWhitespace { index += 1 }
        guard index < source.count else { throw MathParseError.missingArgument }
        guard source[index] == "{" else {
            let character = source[index]
            guard character != "}" else { throw MathParseError.missingArgument }
            index += 1
            return String(character)
        }
        index += 1
        var text = ""
        var depth = 1
        while index < source.count {
            let character = source[index]
            if character == "\\", index + 1 < source.count,
               source[index + 1] == "{" || source[index + 1] == "}" {
                text.append(source[index + 1])
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    index += 1
                    return text
                }
            }
            text.append(character)
            index += 1
        }
        throw MathParseError.unbalancedBrace
    }

    /// A `\begin{env}…\end{env}` block, kept whole. Environments are outside
    /// the subset, so the source is shown as itself rather than half read.
    private mutating func readEnvironment() -> String {
        let start = index - "\\begin".count
        var name = ""
        if index < source.count, source[index] == "{" {
            var scan = index + 1
            while scan < source.count, source[scan] != "}" {
                name.append(source[scan])
                scan += 1
            }
            if scan < source.count { index = scan + 1 }
        }
        let closing = Array("\\end{\(name)}")
        if !name.isEmpty {
            var scan = index
            while scan + closing.count <= source.count {
                if Array(source[scan..<(scan + closing.count)]) == closing {
                    index = scan + closing.count
                    return String(source[start..<index])
                }
                scan += 1
            }
        }
        index = source.count
        return String(source[start..<index])
    }

    /// The delimiter after a `\left` or a `\right`. Anything the subset does
    /// not recognise is taken as `\left.` — invisible — rather than as a
    /// failure, so a stray command never costs the reader the whole formula.
    private mutating func parseDelimiter() throws -> String? {
        while index < source.count, source[index].isWhitespace { index += 1 }
        guard index < source.count else { throw MathParseError.unmatchedDelimiter }
        let character = source[index]
        if character == "\\" {
            guard let name = peekCommandName() else { throw MathParseError.unmatchedDelimiter }
            index += 1 + name.count
            return MathTables.delimiters[name] ?? MathTables.symbols[name]
        }
        index += 1
        if character == "." { return nil }
        return MathTables.delimiters[String(character)] ?? String(character)
    }

    /// `\mathbb{Rn}` — the letters that have a Unicode form take it, and the
    /// rest fall back to a face rather than to a hole in the formula.
    private static func mapped(
        _ text: String, through table: [Character: String], fallback: MathFace
    ) -> MathNode {
        var nodes: [MathNode] = []
        var run = ""
        var runFace = MathFace.upright
        for character in text {
            let mappedFace: MathFace = table[character] == nil ? fallback : .upright
            let piece = table[character] ?? String(character)
            if run.isEmpty || mappedFace == runFace {
                run += piece
                runFace = mappedFace
            } else {
                nodes.append(.run(run, runFace))
                run = piece
                runFace = mappedFace
            }
        }
        if !run.isEmpty { nodes.append(.run(run, runFace)) }
        return nodes.count == 1 ? nodes[0] : .list(nodes)
    }
}

/// The subset's vocabulary: every command name Nota knows and the Unicode it
/// stands for. Generous on purpose — a name that is in here reads as maths,
/// and a name that is not reads as itself, so the table's only job is to move
/// formulas from the second class into the first.
enum MathTables {

    /// `\,` `\;` and the rest, in ems.
    static let spacing: [String: CGFloat] = [
        ",": 0.167, ":": 0.222, ";": 0.278, "!": -0.167, " ": 0.333,
        "quad": 1, "qquad": 2, "thinspace": 0.167, "enspace": 0.5,
    ]

    /// Greek, relations, arrows, set theory, the odds and ends.
    static let symbols: [String: String] = greek.merging(operators) { first, _ in first }
        .merging(arrows) { first, _ in first }
        .merging(shapes) { first, _ in first }

    private static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω",
    ]

    private static let operators: [String: String] = [
        "infty": "∞", "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅",
        "div": "÷", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "ll": "≪", "gg": "≫", "in": "∈", "notin": "∉",
        "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "supseteq": "⊇", "cup": "∪", "cap": "∩", "setminus": "∖",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "wedge": "∧", "vee": "∨",
        "neg": "¬", "lnot": "¬", "forall": "∀", "exists": "∃", "nexists": "∄",
        "emptyset": "∅", "varnothing": "∅", "partial": "∂", "nabla": "∇",
        "surd": "√", "perp": "⊥", "parallel": "∥", "angle": "∠", "top": "⊤",
        "bot": "⊥", "therefore": "∴", "because": "∵", "dagger": "†",
        "%": "%", "&": "&", "#": "#", "_": "_", "$": "$", "{": "{", "}": "}",
        "|": "‖", "backslash": "\\", "prime": "′", "degree": "°",
    ]

    private static let arrows: [String: String] = [
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "Uparrow": "⇑", "Downarrow": "⇓",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "implies": "⟹",
        "iff": "⟺",
    ]

    private static let shapes: [String: String] = [
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        "wp": "℘", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "langle": "⟨", "rangle": "⟩", "vert": "|", "Vert": "‖",
        "checkmark": "✓", "square": "□", "triangle": "△", "diamond": "⋄",
    ]

    /// Delimiters `\left` and `\right` stretch. The single characters are
    /// keyed by themselves, the commands by their name.
    static let delimiters: [String: String] = [
        "(": "(", ")": ")", "[": "[", "]": "]", "|": "|", "/": "/",
        "<": "⟨", ">": "⟩", "{": "{", "}": "}", "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "Vert": "‖", "backslash": "\\",
        "uparrow": "↑", "downarrow": "↓",
    ]

    /// The ones that grow in display and take their scripts as limits.
    static let bigOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
        "bigsqcup": "⨆",
    ]

    /// Words that behave like a big operator: upright, limit underneath.
    static let limitWords: Set<String> = ["lim", "limsup", "liminf", "argmin", "argmax"]

    /// Named functions: upright, with a thin space after so `\sin x` breathes.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "min", "max",
        "det", "gcd", "deg", "dim", "hom", "ker", "arg", "sup", "inf", "mod",
        "Pr",
    ]

    /// Accents, as the combining character that goes on the letter.
    static let accents: [String: Character] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}",
        "overline": "\u{0304}", "vec": "\u{20D7}", "tilde": "\u{0303}",
        "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}",
        "check": "\u{030C}", "breve": "\u{0306}", "acute": "\u{0301}",
        "grave": "\u{0300}", "mathring": "\u{030A}",
    ]

    /// `\mathbb` — the blackboard letters, the famous ones by their own
    /// character and the rest out of the double-struck block.
    static let blackboard: [Character: String] = {
        var table: [Character: String] = [
            "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
        ]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated()
        where table[letter] == nil {
            if let scalar = Unicode.Scalar(0x1D538 + offset) {
                table[letter] = String(Character(scalar))
            }
        }
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            if let scalar = Unicode.Scalar(0x1D552 + offset) {
                table[letter] = String(Character(scalar))
            }
        }
        for (offset, digit) in "0123456789".enumerated() {
            if let scalar = Unicode.Scalar(0x1D7D8 + offset) {
                table[digit] = String(Character(scalar))
            }
        }
        return table
    }()

    /// `\mathcal` — Unicode's script capitals, with the eight that live
    /// outside the block written in by hand.
    static let script: [Character: String] = {
        var table: [Character: String] = [
            "B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ",
            "L": "ℒ", "M": "ℳ", "R": "ℛ",
        ]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated()
        where table[letter] == nil {
            if let scalar = Unicode.Scalar(0x1D49C + offset) {
                table[letter] = String(Character(scalar))
            }
        }
        return table
    }()

    /// The characters that take space around them in a row, as a binary
    /// operator or a relation does on paper.
    static let spaced: Set<Character> = [
        "+", "-", "=", "<", ">", "±", "∓", "×", "⋅", "÷", "≤", "≥", "≠",
        "≈", "≡", "∼", "≃", "≅", "∝", "≪", "≫", "∈", "∉", "∋", "⊂", "⊆",
        "⊃", "⊇", "∪", "∩", "∖", "⊕", "⊖", "⊗", "∧", "∨", "→", "←", "⇒",
        "⇐", "↔", "⇔", "↦", "⟶", "⟵", "⟹", "⟺", "∗", "≔",
    ]

    /// What a superscript looks like in plain Unicode, for `plainText`.
    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]

    /// And what a subscript looks like.
    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ",
        "x": "ₓ", "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "p": "ₚ", "s": "ₛ", "t": "ₜ", "i": "ᵢ", "j": "ⱼ", "r": "ᵣ",
        "u": "ᵤ", "v": "ᵥ",
    ]
}
