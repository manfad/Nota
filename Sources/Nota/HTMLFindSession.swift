import AppKit
import WebKit

/// What a query means in one HTML page: the matches, the bands over them,
/// which one is current, and how ⌘G walks between them.
///
/// The third of the find sessions, after the editor's and the document's, and
/// the only one that cannot see what it is searching. A page is a DOM in
/// another process; there is no string here to scan and no attribute to lay
/// on it. So the search itself is a script injected into every page, and this
/// is the half that asks it questions and puts the answers in the pill —
/// which makes it the only asynchronous one of the three.
///
/// Every answer therefore carries a token. A reply to the query as it was two
/// keystrokes ago is not news about the query being typed now, and the count
/// in the bar must never go backwards because a slower reply landed later.
///
/// Never `WKWebView.find(_:)`. WebKit's own find selects one match at a time:
/// it cannot band the others, cannot count them, and takes the selection away
/// from the reader. All three are the whole of what the pill says.
final class HTMLFindSession {

    /// The same number of bands the editor and the document stop at, and for
    /// the same reason: painting is cheap per match and not free, and a
    /// one-letter query over a long page is a list nobody asked for.
    static let highlightLimit = TextFindSession.highlightLimit

    let bar: FindBarView

    /// Run when the pill arrives or leaves, so the column's mode control can
    /// get out of its corner and come back.
    var onVisibilityChange: ((Bool) -> Void)?

    /// Run whenever the page has answered — a search, a step, a close. There
    /// is no other way to know a reply has landed, so the tests wait on this.
    var onPageAnswered: (() -> Void)?

    /// How many matches the page found, whether the list stopped at the cap,
    /// and which of them the reader is on, counted from zero.
    ///
    /// A count and an index rather than the ranges themselves: the ranges are
    /// the page's, in the page's own process, and nothing here could hold one.
    private(set) var matchCount = 0
    private(set) var isCapped = false
    private(set) var currentMatch: Int?

    /// The query the last search ran with. It outlives the bar, so ⌘G keeps
    /// working after Escape.
    private(set) var query = ""

    /// Which ask the page is answering. Bumped for every question put to it,
    /// so a reply to an earlier one is dropped rather than believed.
    private var token = 0

    var isVisible: Bool { bar.isShown }

    init(bar: FindBarView, webView: @escaping () -> WKWebView?) {
        self.bar = bar
        self.pageProvider = webView
        // A page cannot be typed into, so the glass is only a glass and the
        // replace pill is out of reach.
        bar.canReplace = false
        bar.handlesAction = { Self.handles($0) }
        bar.onFinderAction = { [weak self] action in self?.perform(action) }
        bar.onQueryChange = { [weak self] _ in self?.runSearch() }
        bar.onVisibilityChange = { [weak self] shown in self?.onVisibilityChange?(shown) }
    }

    /// How the page is reached. A `WKWebView` is a pair of processes and the
    /// pane does not start one until a `.html` tab is actually read, so the
    /// session is given a way to ask for it rather than the view itself.
    private let pageProvider: () -> WKWebView?
    private var page: WKWebView? { pageProvider() }

    // MARK: - The menu's actions

    /// Which of `NSTextFinder`'s actions a page answers for. Not the replace
    /// half: a preview is not a second place to edit the file, so Find and
    /// Replace… is greyed out over it rather than opening a pill that could
    /// do nothing.
    static func handles(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface, .hideFindInterface, .nextMatch, .previousMatch,
             .setSearchString:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func perform(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface: show()
        case .hideFindInterface: hide()
        case .nextMatch: step(forward: true)
        case .previousMatch: step(forward: false)
        case .setSearchString: useSelectionForFind()
        default: return false
        }
        return true
    }

    // MARK: - Opening and closing

    /// ⌘F. The pill comes up at once — it is chrome, and chrome does not wait
    /// on another process — and the page is asked for its selection after,
    /// since that is the one thing only it knows.
    func show() {
        bar.setShown(true)
        bar.focusField()
        guard let page else {
            runSearch()
            return
        }
        // What the field held when the bar came up. A reader does not wait on
        // another process before typing, so a selection that comes back after
        // they have started is a stale answer to a question they have already
        // answered themselves — and putting it in the field would take their
        // query away from them mid-word.
        let opened = bar.query
        askForSelection(in: page) { [weak self] selected in
            guard let self else { return }
            if let selected, !selected.isEmpty, bar.query == opened {
                bar.query = selected
                bar.focusField()
            }
            runSearch()
        }
    }

    /// Escape, the ✕, or Hide Find Interface. The bands go down and the match
    /// the reader was on is handed over as a real selection — there is no
    /// field holding the keyboard any more, so nothing is drawing over it —
    /// and the keyboard goes back to the page.
    func hide() {
        guard bar.isShown else { return }
        bar.setShown(false)
        ask("close()") { [weak self] _ in self?.onPageAnswered?() }
        guard let page else { return }
        page.window?.makeFirstResponder(page)
    }

    /// The tab in front changed, or the page was loaded again: the ranges the
    /// bands were painted on belong to a document that is no longer there.
    func close() {
        matchCount = 0
        isCapped = false
        currentMatch = nil
        token += 1
        guard bar.isShown else { return }
        hide()
    }

    /// A fresh page of the same note — an edit in the editor beside it. The
    /// ranges went with the old document, so the query is put to the new one.
    func refresh() {
        guard bar.isShown else { return }
        runSearch()
    }

    // MARK: - Searching

    /// One pass of the query. The page is asked from the top of what the
    /// reader can see, so typing finds the first thing on screen rather than
    /// the first thing in a page they scrolled past ten screens ago.
    private func runSearch() {
        query = bar.query
        ask("search(\(Self.literal(bar.query)), window.scrollY)") { [weak self] report in
            self?.take(report)
        }
    }

    /// ⌘G and ⇧⌘G, and Return and ⇧Return in the field. Both wrap round the
    /// end of the page, and both work with the bar closed — the query
    /// outlives it. The query goes with the step, so a page loaded again
    /// under a closed bar finds its matches afresh rather than stepping
    /// through nothing.
    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        ask("step(\(Self.literal(query)), \(forward ? 1 : -1), window.scrollY)") {
            [weak self] report in self?.take(report)
        }
    }

    /// ⌘E. What is selected in the page becomes the query — here and on the
    /// find pasteboard, so it is the string the next app's ⌘G looks for too —
    /// without opening the bar or moving off what is selected.
    func useSelectionForFind() {
        guard let page else { return }
        askForSelection(in: page) { [weak self] selected in
            guard let self, let selected, !selected.isEmpty else { return }
            bar.query = selected
            query = selected
            let board = NSPasteboard(name: .find)
            board.clearContents()
            board.setString(selected, forType: .string)
            if bar.isShown { runSearch() } else { onPageAnswered?() }
        }
    }

    // MARK: - Talking to the page

    /// Puts one question to the find script and takes the answer, unless a
    /// later question was asked while this one was in flight.
    private func ask(_ call: String, then handle: @escaping ([String: Any]?) -> Void) {
        token += 1
        let mine = token
        guard let page else {
            handle(nil)
            return
        }
        page.evaluateJavaScript(
            "window.\(Self.namespace) ? window.\(Self.namespace).\(call) : null",
            in: nil, in: .defaultClient
        ) { [weak self] outcome in
            guard let self, mine == self.token else { return }
            guard case .success(let value) = outcome else { return handle(nil) }
            handle(value as? [String: Any])
        }
    }

    private func askForSelection(in page: WKWebView, then handle: @escaping (String?) -> Void) {
        page.evaluateJavaScript(
            "window.getSelection ? window.getSelection().toString() : ''",
            in: nil, in: .defaultClient
        ) { outcome in
            guard case .success(let value) = outcome else { return handle(nil) }
            handle(value as? String)
        }
    }

    /// What the page said about the last question: how many matches there are
    /// now, whether it stopped counting, and which one the reader is on.
    private func take(_ report: [String: Any]?) {
        matchCount = report?["count"] as? Int ?? 0
        isCapped = report?["capped"] as? Bool ?? false
        let index = report?["index"] as? Int ?? -1
        currentMatch = index >= 0 ? index : nil
        updateStatus()
        onPageAnswered?()
    }

    /// A Swift string as a JavaScript one, quotes and all. Built by the JSON
    /// encoder rather than by hand: a query is whatever the reader typed, and
    /// a quote or a backslash in it must not become part of the program.
    private static func literal(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - The count

    /// `"3 of 12"` while there are matches and one of them is current,
    /// `"12 matches"` when none is, `"No matches"` when there are none, and
    /// nothing at all while the field is empty. A page long enough to have
    /// stopped the list says `2000+` for the total.
    private func updateStatus() {
        guard !query.isEmpty else {
            bar.setStatus(nil)
            return
        }
        guard matchCount > 0 else {
            bar.setStatus("No matches")
            return
        }
        let total = isCapped ? "\(Self.highlightLimit)+" : "\(matchCount)"
        guard let currentMatch else {
            bar.setStatus(matchCount == 1 && !isCapped ? "1 match" : "\(total) matches")
            return
        }
        bar.setStatus("\(currentMatch + 1) of \(total)")
    }
}

// MARK: - The script the page is searched by

extension HTMLFindSession {

    /// The one global the script hangs off. Injected in `.defaultClient`, the
    /// same separate world the scroll reporter talks from, so the page cannot
    /// see it, shadow it or trip over it.
    static let namespace = "__notaFind"

    /// The search itself, injected into every page.
    ///
    /// Every text node in the document is gathered into one string, so a match
    /// that runs across an inline element — `ca<b>fe</b>` — is still a match.
    /// That string is folded once for comparison: decomposed, stripped of
    /// combining marks and lowercased, a character at a time, with a map back
    /// to where each folded character came from. Folding the whole string in
    /// one call would be shorter and wrong — `é` is one character and `e` is
    /// one character, but `İ` lowercases to two, and every offset after it
    /// would point at the wrong letter.
    ///
    /// The bands are CSS custom highlights: ranges handed to the engine to
    /// paint, drawn over the page without a single node being added to it or
    /// an attribute written on it. Nothing a search does can reach the
    /// author's DOM, which is the same promise the editor's temporary
    /// attributes make about the text.
    static func script(quietBand: NSColor, currentBand: NSColor) -> String {
        """
        (function () {
            var style = document.createElement('style');
            style.textContent =
                '::highlight(nota-find) { background-color: \(css(quietBand)); }' +
                '::highlight(nota-find-current) { background-color: \(css(currentBand));'
                    + ' color: #000; }';
            (document.head || document.documentElement).appendChild(style);

        \(body)
        })();
        """
    }

    /// A colour as CSS. `findHighlightColor` is the same light colour in both
    /// appearances, so it is resolved once, when the page's view is built.
    private static func css(_ colour: NSColor) -> String {
        let resolved = colour.usingColorSpace(.sRGB) ?? .yellow
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "rgba(%d, %d, %d, %.3f)",
            channel(resolved.redComponent), channel(resolved.greenComponent),
            channel(resolved.blueComponent), resolved.alphaComponent
        )
    }

    /// The body of the script, kept raw so its own backslashes are its own.
    private static var body: String {
        #"""
            var LIMIT = \#(highlightLimit);
            var state = { query: '', ranges: [], index: -1, capped: false };

            function report() {
                return { count: state.ranges.length, capped: state.capped,
                         index: state.index };
            }

            // One character at a time, so the map back to the original text
            // survives a letter whose folded form is a different length.
            function fold(text) {
                var folded = '', map = [];
                for (var i = 0; i < text.length; i++) {
                    var one = text[i].normalize('NFD')
                        .replace(/[\u0300-\u036f]/g, '').toLowerCase();
                    for (var k = 0; k < one.length; k++) { folded += one[k]; map.push(i); }
                }
                map.push(text.length);
                return { folded: folded, map: map };
            }

            // Every text node the reader can actually read, as one string.
            function collect() {
                var root = document.body || document.documentElement;
                if (!root) { return { nodes: [], starts: [], text: '' }; }
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                    acceptNode: function (node) {
                        var parent = node.parentNode;
                        if (!parent) { return NodeFilter.FILTER_REJECT; }
                        var name = parent.nodeName;
                        if (name === 'SCRIPT' || name === 'STYLE' || name === 'NOSCRIPT') {
                            return NodeFilter.FILTER_REJECT;
                        }
                        return node.nodeValue.length
                            ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                    }
                });
                var nodes = [], starts = [], text = '', node;
                while ((node = walker.nextNode())) {
                    nodes.push(node);
                    starts.push(text.length);
                    text += node.nodeValue;
                }
                return { nodes: nodes, starts: starts, text: text };
            }

            // Which node an offset into that string lands in, and where.
            function place(doc, offset) {
                var low = 0, high = doc.nodes.length - 1;
                while (low < high) {
                    var mid = (low + high + 1) >> 1;
                    if (doc.starts[mid] <= offset) { low = mid; } else { high = mid - 1; }
                }
                return { node: doc.nodes[low], offset: offset - doc.starts[low] };
            }

            function makeRange(doc, from, to) {
                var start = place(doc, from), end = place(doc, to - 1);
                var range = document.createRange();
                try {
                    range.setStart(start.node, start.offset);
                    range.setEnd(end.node, end.offset + 1);
                } catch (error) { return null; }
                return range;
            }

            // The two bands, made once and registered once for the life of
            // the document.
            //
            // Not a fresh `Highlight` set under the same name on every
            // keystroke. A highlight is a set, and the engine repaints what it
            // covered when the set itself changes; replacing the registry
            // entry wholesale asks the engine to notice by another route, and
            // a query growing a letter at a time left the first letter's bands
            // on the page. So the objects are stable and only their contents
            // move.
            var quietBand = null, currentBand = null;

            function bands() {
                if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') {
                    return false;
                }
                if (!quietBand) {
                    quietBand = new Highlight();
                    currentBand = new Highlight();
                }
                if (CSS.highlights.get('nota-find') !== quietBand) {
                    CSS.highlights.set('nota-find', quietBand);
                }
                if (CSS.highlights.get('nota-find-current') !== currentBand) {
                    CSS.highlights.set('nota-find-current', currentBand);
                }
                return true;
            }

            function paint() {
                if (!bands()) { return; }
                quietBand.clear();
                currentBand.clear();
                for (var i = 0; i < state.ranges.length; i++) {
                    (i === state.index ? currentBand : quietBand).add(state.ranges[i]);
                }
            }

            function unpaint() {
                if (!bands()) { return; }
                quietBand.clear();
                currentBand.clear();
            }

            // The first match at or below the top of what the reader can see,
            // and the first in the page when they are all above it.
            function firstFrom(y) {
                for (var i = 0; i < state.ranges.length; i++) {
                    var box = state.ranges[i].getBoundingClientRect();
                    if (box.top + window.scrollY >= y - 1) { return i; }
                }
                return state.ranges.length ? 0 : -1;
            }

            function reveal() {
                var range = state.ranges[state.index];
                if (!range) { return; }
                var target = range.startContainer.parentElement;
                if (target && target.scrollIntoView) {
                    target.scrollIntoView({ block: 'center', inline: 'nearest' });
                }
            }

            function search(query, fromY) {
                unpaint();
                state = { query: query, ranges: [], index: -1, capped: false };
                if (!query) { return report(); }
                var doc = collect();
                var haystack = fold(doc.text);
                var needle = fold(query).folded;
                if (!needle || !doc.nodes.length) { return report(); }
                var at = 0;
                while (true) {
                    var hit = haystack.folded.indexOf(needle, at);
                    if (hit < 0) { break; }
                    var range = makeRange(doc, haystack.map[hit],
                                          haystack.map[hit + needle.length]);
                    if (range) { state.ranges.push(range); }
                    if (state.ranges.length >= LIMIT) { state.capped = true; break; }
                    at = hit + needle.length;
                }
                state.index = firstFrom(fromY);
                paint();
                reveal();
                return report();
            }

            function step(query, delta, fromY) {
                // A page loaded again under a closed bar has no ranges left:
                // the query finds them afresh and lands on the first, which is
                // where a ⌘G after a reload belongs.
                if (query !== state.query) { return search(query, fromY); }
                if (!state.ranges.length) { return report(); }
                var count = state.ranges.length;
                state.index = ((state.index + delta) % count + count) % count;
                paint();
                reveal();
                return report();
            }

            // Escape. The bands go down and the match the reader was on
            // becomes a real selection, so it is still there to be seen.
            function close() {
                unpaint();
                var range = state.ranges[state.index];
                var selection = window.getSelection();
                if (range && selection) {
                    selection.removeAllRanges();
                    selection.addRange(range);
                }
                return report();
            }

            // `bandsAreStable` is for the tests: whether the two highlights
            // registered now are the two objects made for this document, which
            // is the property the bands' repainting rests on.
            function bandsAreStable() {
                return !!quietBand
                    && CSS.highlights.get('nota-find') === quietBand
                    && CSS.highlights.get('nota-find-current') === currentBand;
            }

            window.\#(namespace) = { search: search, step: step, close: close,
                                     report: report, bandsAreStable: bandsAreStable };
        """#
    }
}
