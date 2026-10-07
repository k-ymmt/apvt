import APVTCore
import APVTModel
import ArgumentParser
import Foundation

@main
struct APVT: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apvt",
        abstract: "See what your views really look like: layout issues, the view tree and frames of a running iOS Simulator app.",
        discussion: """
        apvt reads the live UI of an app in the iOS Simulator — UIKit views and SwiftUI views \
        alike, with frames in screen points — and reports layout mistakes: content past the \
        screen edge, truncated or squeezed text, overlaps, clipping, the unsafe area, tiny tap \
        targets, ambiguous and broken Auto Layout constraints. The app needs no code changes: \
        a small agent library is loaded into it at launch.

        WORKFLOW
          1. apvt setup            once per simulator boot
          2. launch the app        xcrun simctl launch, or the home screen;
                                   from Xcode or Xcode MCP, pass the variables
                                   of `apvt launch-env` to the launch instead
          3. go to the screen      with your usual tools (taps, deep links);
                                   apvt type "text" fills the focused field
          4. apvt inspect          issues on the current screen, with @N
          5. apvt query @N         one node: ancestors, text metrics, issues
             apvt tree             the view tree with frames
             apvt assert <sel> …   check what you meant (--inside screen, …)
             apvt screenshot f.png issues outlined and labelled @N
          6. fix, rebuild, relaunch, apvt inspect again

        SELECTORS (query, assert, tree --root)
          @12   #identifier   text:Sub   text="Exact text"   type:Button
          role:control   type:Text,text:Inbox (terms joined by commas)

        Frames are points, origin top-left of the screen: (x,y widthxheight).
        Exit codes: 0 ok, 1 a check failed (assert; inspect found an error),
        2 usage, 3 environment or app. Every command takes --json.
        Right after launching an app, add --wait 10 so apvt waits for it.
        `apvt rules` lists what inspect checks and how to fix each.
        """,
        version: "0.1.0",
        subcommands: [Setup.self, Teardown.self, Status.self, LaunchEnv.self, Inspect.self, Tree.self, Query.self, Assert.self,
                      Screenshot.self, TypeText.self, Rules.self, Debug.self]
    )
}

// MARK: - Shared options

struct TargetOptions: ParsableArguments {
    @Option(help: "Simulator name or UDID. Default: the only booted simulator.")
    var device: String?

    @Option(help: "Bundle id (or process name) of the app. Default: the only running app that has the agent.")
    var app: String?

    @Option(help: ArgumentHelp("Read a snapshot saved with --save instead of asking the running app.", valueName: "file.json"))
    var snapshot: String?

    @Option(help: ArgumentHelp("Wait up to this many seconds for the app's agent to appear, e.g. right after launching it.", valueName: "seconds"))
    var wait: Double = 0

    @Option(help: .hidden)
    var platform: String = "ios-simulator"

    var target: Target { Target(device: device, app: app, snapshotFile: snapshot, wait: wait) }
}

struct JSONFlag: ParsableArguments {
    @Flag(help: "Print JSON instead of text.")
    var json = false
}

/// Runs a command body; errors become the agent-friendly text (or JSON) and an exit code.
func run(json: Bool, _ body: () throws -> Int32) throws {
    do {
        let code = try body()
        if code != 0 { throw ExitCode(code) }
    } catch let error as APVTError {
        if json {
            printJSON(error.json)
        } else {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
        }
        throw ExitCode(error.exitCode)
    }
}

func printJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func parseRules(_ names: [String]) throws -> Set<Rule> {
    guard !names.isEmpty else { return Set(Rule.allCases) }
    var rules = Set<Rule>()
    for name in names.flatMap({ $0.split(separator: ",").map(String.init) }) {
        guard let rule = Rule(rawValue: name) else {
            throw APVTError(.usage, "unknown rule \"\(name)\"", fix: ["rules: " + Rule.allCases.map(\.rawValue).joined(separator: ", ")])
        }
        rules.insert(rule)
    }
    return rules
}

// MARK: - setup / teardown / status

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make apps launched on the simulator from now on load the apvt agent.",
        discussion: """
        Builds the agent for the simulator (first run, a few seconds; cached), then sets \
        DYLD_INSERT_LIBRARIES in the simulator's launchd so every app launched afterwards — by \
        simctl or the home screen — loads it. Apps already running must be \
        relaunched. Lasts until the simulator shuts down.

        Xcode's Run passes its own DYLD_INSERT_LIBRARIES (Main Thread Checker), which replaces \
        launchd's, so an app Xcode starts has no agent. Either relaunch it with \
        `xcrun simctl launch <udid> <bundle-id>`, or give the launch the variables of \
        `apvt launch-env` (Xcode MCP DeviceInteractionInstallAndRun's environmentVariables, or \
        the scheme's Run environment).
        """
    )

    @Option(help: "Simulator name or UDID. Default: the only booted simulator.")
    var device: String?
    @Flag(help: "Rebuild the agent even if a cached build exists.")
    var rebuild = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let report = try Session.platform("ios-simulator").setup(SetupOptions(device: device, rebuild: rebuild))
            if output.json { printJSON(report); return 0 }
            print("set up \(report.device):")
            report.actions.forEach { print("- \($0)") }
            print("next:")
            report.next.forEach { print("- \($0)") }
            return 0
        }
    }
}

struct Teardown: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo apvt setup: apps launched from now on run without the agent.")

    @Option(help: "Simulator name or UDID. Default: the only booted simulator.")
    var device: String?
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let report = try Session.platform("ios-simulator").teardown(SetupOptions(device: device))
            if output.json { printJSON(report); return 0 }
            print("tore down \(report.device):")
            report.actions.forEach { print("- \($0)") }
            return 0
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show booted simulators, whether they are set up, and which apps have the agent.")

    @Option(help: "Simulator name or UDID. Default: every booted simulator.")
    var device: String?
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let status = try Session.platform("ios-simulator").status(device: device)
            if output.json { printJSON(status); return 0 }
            if status.devices.isEmpty { print("no booted simulator (xcrun simctl boot <udid>)") }
            for d in status.devices {
                print("\(d.name) (\(d.runtime), \(d.udid)): \(d.setUp ? "set up" : "NOT set up — run apvt setup")")
                for a in d.agents {
                    print("  agent: \(a.bundleId) (\(a.name), pid \(a.pid), loaded by \(a.loadedBy)\(a.swiftUIDebug ? "" : ", SwiftUI debug off"))")
                }
                for bundle in d.appsWithoutAgent {
                    print("  running without agent: \(bundle) — relaunch: xcrun simctl terminate \(d.udid) \(bundle) && xcrun simctl launch \(d.udid) \(bundle)")
                }
                if d.agents.isEmpty && d.appsWithoutAgent.isEmpty { print("  no user app running") }
            }
            if status.oldLLDBHook { print("an old apvt hook is still in ~/.lldbinit or ~/.lldbinit-Xcode: apvt teardown (or apvt setup) removes it") }
            print("agent build: \(status.agentBuild ?? "not built yet")")
            return 0
        }
    }
}

struct LaunchEnv: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch-env",
        abstract: "Print the environment variables that make an app launched by Xcode load the agent.",
        discussion: """
        For launches apvt setup cannot reach: Xcode's Run and Xcode MCP's \
        DeviceInteractionInstallAndRun pass their own DYLD_INSERT_LIBRARIES, which replaces \
        the one apvt setup puts into launchd. Pass these variables to that launch instead, for \
        example as DeviceInteractionInstallAndRun's environmentVariables (--xcode adds \
        "$(inherited)": "" to keep the scheme's own), or in the scheme's Run > Environment Variables. The app then \
        runs under Xcode, with its console, and answers apvt. Builds the agent if needed and \
        turns on the simulator's application accessibility (as setup does); launchd is left \
        alone.
        """
    )

    @Option(help: "Simulator name or UDID. Default: the only booted simulator.")
    var device: String?
    @Flag(help: "Print KEY=value lines instead of JSON.")
    var shell = false
    @Flag(help: ArgumentHelp("Add \"$(inherited)\": \"\" so the JSON can be passed as-is to Xcode MCP's DeviceInteractionInstallAndRun environmentVariables, keeping the scheme's own variables."))
    var xcode = false

    func run() throws {
        try apvt.run(json: !shell) {
            var env = try Session.launchEnvironment(device: device)
            if xcode { env["$(inherited)"] = "" }
            if shell {
                env.keys.sorted().forEach { print("\($0)=\(env[$0]!)") }
            } else {
                printJSON(env)
            }
            return 0
        }
    }
}

// MARK: - type

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the text field that has keyboard focus in the app.",
        discussion: """
        Tap the field first (with the tool that drives the simulator), then: apvt type "hello". \
        The agent inserts the text through UIKeyInput, as the keyboard does, so SwiftUI \
        bindings, delegates and .onChange see it. --replace clears the field first; --submit \
        presses Return afterwards (textFieldShouldReturn, SwiftUI .onSubmit). Prints the field \
        and its value afterwards. Faster and more reliable than tapping keys one by one, and \
        independent of the keyboard layout.
        """
    )

    @Argument(help: "The text to type. Use \"\" with --submit to press Return only.")
    var text: String
    @Flag(help: "Replace the field's text instead of inserting at the cursor.")
    var replace = false
    @Flag(help: "Press Return after typing.")
    var submit = false
    @OptionGroup var target: TargetOptions
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let platform = try Session.platform(target.platform)
            let (response, agent) = try Session.type(platform, target.target, text: text, replace: replace, submit: submit)
            if output.json { printJSON(response); return 0 }
            print("typed into \(response.focused ?? "?") of \(agent.title)")
            print("value: \(response.value.map { "\"\($0)\"" } ?? "-")")
            if submit { print("focus after Return: \(response.focusedAfter ?? "none (editing ended)")") }
            return 0
        }
    }
}

// MARK: - inspect

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report layout issues on the app's current screen.",
        discussion: """
        Each issue names a node (@N, as in apvt tree / query) and its frame in points, and ends \
        with how to fix that kind of issue in SwiftUI and UIKit. Run `apvt rules` for the list.
        """
    )

    @OptionGroup var target: TargetOptions
    @Option(name: .customLong("rule"), help: ArgumentHelp("Only these rules (repeatable or comma-separated).", valueName: "name"))
    var rules: [String] = []
    @Option(help: "Show at most this many issues (0 = all).")
    var limit: Int = 40
    @Option(help: ArgumentHelp("Exit 1 when an issue of this severity (or worse) is found: error, warning, never.", valueName: "severity"))
    var failOn: String = "error"
    @Option(help: "Smallest tappable size in points for small-target.")
    var minTarget: Double = 24
    @Option(help: ArgumentHelp("Also save the snapshot as JSON (for --snapshot later, or diffing).", valueName: "file.json"))
    var save: String?
    @Option(help: ArgumentHelp("Also write a screenshot with the issues outlined.", valueName: "file.png"))
    var annotate: String?
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let platform = try Session.platform(target.platform)
            let (s, agent) = try Session.snapshot(platform, target.target)
            var analyzer = Analyzer()
            analyzer.rules = try parseRules(rules)
            analyzer.minimumTarget = minTarget
            let issues = analyzer.analyze(s)
            if let save { try Session.save(s.snapshot, to: save) }
            if let annotate {
                guard let agent else { throw APVTError(.usage, "--annotate needs a running app, not --snapshot") }
                try writeAnnotated(platform, agent, s, issues, path: annotate, outline: .issues)
            }
            let report = InspectReport(s, issues: issues)
            if output.json {
                printJSON(report)
            } else {
                print(InspectReport.header(s.snapshot))
                print(report.text(limit: limit == 0 ? nil : limit))
                if let annotate { print("annotated screenshot: \(annotate)") }
            }
            switch failOn {
            case "never": return 0
            case "warning": return issues.isEmpty ? 0 : 1
            case "error": return issues.contains { $0.severity == .error } ? 1 : 0
            default: throw APVTError(.usage, "--fail-on takes error, warning or never")
            }
        }
    }
}

func writeAnnotated(_ platform: any Platform, _ agent: RunningAgent, _ s: IndexedSnapshot, _ issues: [Issue],
                    path: String, outline: Annotator.Outline) throws {
    let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "apvt-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: raw) }
    try platform.screenshot(of: agent, to: raw)
    try Annotator.annotate(screenshot: raw, output: URL(fileURLWithPath: path), snapshot: s, issues: issues, outline: outline)
}

// MARK: - tree / query

struct Tree: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the view tree with frames (UIKit and SwiftUI), numbered @N.",
        discussion: """
        Lines read `@N Type #identifier "text" (x,y wxh) [SwiftUI modifiers] {traits} !issues`. \
        Private framework views are omitted (their children are kept), system chrome (navigation \
        bar, keyboard) is folded, and same-frame chains print as `A > B`. --all shows everything.
        """
    )

    @OptionGroup var target: TargetOptions
    @Flag(help: "Include private views and system chrome.")
    var all = false
    @Option(help: "Stop this many levels below the root.")
    var depth: Int?
    @Option(help: ArgumentHelp("Print only the subtree of the first node this selector matches.", valueName: "selector"))
    var root: String?
    @Option(help: ArgumentHelp("Also save the snapshot as JSON.", valueName: "file.json"))
    var save: String?
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let (s, _) = try Session.snapshot(try Session.platform(target.platform), target.target)
            if let save { try Session.save(s.snapshot, to: save) }
            if output.json {
                printJSON(s.snapshot)
                return 0
            }
            var formatter = TreeFormatter()
            formatter.showAll = all
            formatter.maxDepth = depth
            if let root {
                let selector = try NodeSelector(root)
                guard let first = selector.select(in: s, includeSystem: all).first else {
                    throw APVTError(.usage, "no node matches \(root)", fix: ["apvt tree   # without --root, to find it"])
                }
                formatter.root = first.ref
            }
            print(InspectReport.header(s.snapshot))
            print(formatter.format(s, issues: Analyzer().analyze(s)))
            for note in s.snapshot.notes { print("note: \(note)") }
            return 0
        }
    }
}

struct Query: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the nodes a selector matches: frame, ancestors, text metrics, issues.",
        discussion: "Selectors: @12, #identifier, text:Sub, text=\"Exact\", type:Button, role:text; join terms with commas."
    )

    @OptionGroup var target: TargetOptions
    @Argument(help: "What to find, e.g. #follow, text:Follow, type:Text,text:Inbox, @12.")
    var selector: String
    @Flag(help: "Also match system chrome and private views.")
    var includeSystem = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let sel = try NodeSelector(selector)
            let (s, _) = try Session.snapshot(try Session.platform(target.platform), target.target)
            let issues = Analyzer().analyze(s)
            let matches = sel.select(in: s, includeSystem: includeSystem)
            if output.json {
                printJSON(matches.map { e -> QueryMatch in
                    QueryMatch(ref: e.ref, node: e.node, ancestors: e.ancestors, children: e.childRefs, hidden: e.hidden,
                               issues: issues.filter { $0.ref == e.ref || $0.related.contains(e.ref) })
                })
            } else {
                print(QueryFormatter.text(matches, in: s, issues: issues))
            }
            return matches.isEmpty ? 1 : 0
        }
    }
}

struct QueryMatch: Encodable {
    var ref: Int
    var node: Node
    var ancestors: [Int]
    var children: [Int]
    var hidden: Bool
    var issues: [Issue]
}

// MARK: - assert

struct Assert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that views are where you meant them to be. Exit 1 if any check fails.",
        discussion: """
        Every node the selector matches is checked; with no checks, assert checks that it exists. \
        References (--inside, --align-*, --left-of, …) are a selector that matches exactly one \
        node, or `screen` / `safe-area`. Sizes take an operator: 150, ">=44", "<=100".

        EXAMPLES
          apvt assert '#follow' --visible --inside screen --min-width 44
          apvt assert 'type:Text,text:Inbox' --not-truncated --no-overlap
          apvt assert '#plan-free' --same-width '#plan-pro' \\
            --align-top '#plan-pro' --left-of '#plan-pro' --spacing 12
          apvt assert 'type:Button' --count 3
        """
    )

    @OptionGroup var target: TargetOptions
    @Argument(help: "The nodes to check.")
    var selector: String

    @Option(help: "Exactly this many nodes match.") var count: Int?
    @Flag(help: "On screen, not hidden, not clipped, not zero-sized.") var visible = false
    @Option(help: ArgumentHelp("Frame lies within screen, safe-area, or a node.", valueName: "ref")) var inside: [String] = []
    @Flag(help: "No truncated / squeezed / clipped issue on it.") var notTruncated = false
    @Flag(help: "Overlaps no other text or control.") var noOverlap = false
    @Flag(help: "No issue of any rule on it.") var noIssues = false
    @Option(help: ArgumentHelp("Width, e.g. 150 or \">=44\".", valueName: "size")) var width: String?
    @Option(help: ArgumentHelp("Height, e.g. 44 or \"<=100\".", valueName: "size")) var height: String?
    @Option(help: ArgumentHelp("Same as --width \">=N\".", valueName: "N")) var minWidth: Double?
    @Option(help: ArgumentHelp("Same as --height \">=N\".", valueName: "N")) var minHeight: Double?
    @Option(help: ArgumentHelp("Left edges equal.", valueName: "ref")) var alignLeading: [String] = []
    @Option(help: ArgumentHelp("Right edges equal.", valueName: "ref")) var alignTrailing: [String] = []
    @Option(help: ArgumentHelp("Top edges equal.", valueName: "ref")) var alignTop: [String] = []
    @Option(help: ArgumentHelp("Bottom edges equal.", valueName: "ref")) var alignBottom: [String] = []
    @Option(help: ArgumentHelp("Horizontal centers equal.", valueName: "ref")) var alignCenterX: [String] = []
    @Option(help: ArgumentHelp("Vertical centers equal.", valueName: "ref")) var alignCenterY: [String] = []
    @Option(help: ArgumentHelp("Width equal to the reference's.", valueName: "ref")) var sameWidth: [String] = []
    @Option(help: ArgumentHelp("Height equal to the reference's.", valueName: "ref")) var sameHeight: [String] = []
    @Option(help: ArgumentHelp("Entirely left of the reference.", valueName: "ref")) var leftOf: [String] = []
    @Option(help: ArgumentHelp("Entirely right of the reference.", valueName: "ref")) var rightOf: [String] = []
    @Option(help: ArgumentHelp("Entirely above the reference.", valueName: "ref")) var above: [String] = []
    @Option(help: ArgumentHelp("Entirely below the reference.", valueName: "ref")) var below: [String] = []
    @Option(help: ArgumentHelp("With --left-of/--right-of/--above/--below: the gap, e.g. 12 or \">=8\".", valueName: "size")) var spacing: String?
    @Option(help: "Points of slack for equality checks.") var tolerance: Double = 0.5
    @Flag(help: "Also match system chrome and private views.") var includeSystem = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            let sel = try NodeSelector(selector)
            var spec = AssertionSpec()
            spec.count = count
            spec.visible = visible
            spec.inside = try inside.map(AssertionSpec.Reference.init)
            spec.notTruncated = notTruncated
            spec.noOverlap = noOverlap
            spec.noIssues = noIssues
            spec.width = try width.map(AssertionSpec.Comparison.init) ?? minWidth.map { try AssertionSpec.Comparison(">=\($0)") }
            spec.height = try height.map(AssertionSpec.Comparison.init) ?? minHeight.map { try AssertionSpec.Comparison(">=\($0)") }
            let alignments: [(AssertionSpec.Edge, [String])] = [(.leading, alignLeading), (.trailing, alignTrailing), (.top, alignTop),
                                                                  (.bottom, alignBottom), (.centerX, alignCenterX), (.centerY, alignCenterY)]
            for (edge, refs) in alignments {
                for r in refs { spec.aligned.append((edge, try AssertionSpec.Reference(r))) }
            }
            spec.sameWidth = try sameWidth.map(AssertionSpec.Reference.init)
            spec.sameHeight = try sameHeight.map(AssertionSpec.Reference.init)
            let directions: [(AssertionSpec.Direction, [String])] = [(.leftOf, leftOf), (.rightOf, rightOf), (.above, above), (.below, below)]
            for (direction, refs) in directions {
                for r in refs { spec.relative.append((direction, try AssertionSpec.Reference(r))) }
            }
            spec.spacing = try spacing.map(AssertionSpec.Comparison.init)
            spec.tolerance = tolerance

            let (s, _) = try Session.snapshot(try Session.platform(target.platform), target.target)
            let issues = Analyzer().analyze(s)
            let results = try Assertions.evaluate(spec, selector: sel, in: s, issues: issues, includeSystem: includeSystem)
            let failed = results.filter { !$0.passed }
            if output.json {
                printJSON(AssertReport(passed: failed.isEmpty, results: results))
            } else {
                for r in results {
                    print("\(r.passed ? "PASS" : "FAIL") \(r.node): \(r.check) — \(r.detail)")
                }
                print(failed.isEmpty ? "all \(results.count) check(s) passed" : "\(failed.count) of \(results.count) check(s) failed")
            }
            return failed.isEmpty ? 0 : 1
        }
    }
}

struct AssertReport: Encodable {
    var passed: Bool
    var results: [AssertionResult]
}

// MARK: - screenshot

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a screenshot with issues outlined and labelled @N (red: error, orange: warning).",
        discussion: "Dashed outlines are the other nodes an issue involves. --outline all also boxes every visible element in blue with its @N."
    )

    @OptionGroup var target: TargetOptions
    @Argument(help: "Where to write the PNG.")
    var path: String
    @Option(help: "issues (default) or all.")
    var outline: String = "issues"
    @Flag(help: "Do not draw anything; the plain screenshot.")
    var plain = false
    @OptionGroup var output: JSONFlag

    func run() throws {
        try apvt.run(json: output.json) {
            guard target.snapshot == nil else { throw APVTError(.usage, "screenshot needs a running app, not --snapshot") }
            let platform = try Session.platform(target.platform)
            let agent = try Session.agent(platform, target.target)
            if plain {
                try platform.screenshot(of: agent, to: URL(fileURLWithPath: path))
                if output.json { printJSON(["path": path]) } else { print("wrote \(path)") }
                return 0
            }
            guard let mode = Annotator.Outline(rawValue: outline) else {
                throw APVTError(.usage, "--outline takes issues or all")
            }
            let s = IndexedSnapshot(try platform.snapshot(of: agent))
            let issues = Analyzer().analyze(s)
            try writeAnnotated(platform, agent, s, issues, path: path, outline: mode)
            if output.json {
                printJSON(["path": path, "issues": issues.count] as [String: Any])
            } else {
                print("wrote \(path) (\(issues.count) issue\(issues.count == 1 ? "" : "s") outlined; points × \(Describe.number(s.snapshot.screen.scale)) = pixels)")
                for issue in issues.prefix(20) {
                    print("  @\(issue.ref.map(String.init) ?? "-") \(issue.rule.rawValue)")
                }
            }
            return 0
        }
    }
}

// MARK: - rules / debug

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List what apvt inspect checks, and how to fix each.")
    @OptionGroup var output: JSONFlag

    func run() throws {
        if output.json {
            printJSON(Rule.allCases.map { ["rule": $0.rawValue, "summary": $0.summary, "fix": $0.hint] })
            return
        }
        for rule in Rule.allCases {
            print("\(rule.rawValue): \(rule.summary)\n  fix: \(rule.hint)")
        }
    }
}

struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnostics for apvt itself: raw SwiftUI debug data, a class's selectors.",
        subcommands: [SwiftUIRaw.self, Methods.self]
    )

    struct SwiftUIRaw: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "swiftui-raw", abstract: "Write every hosting view's raw makeViewDebugData JSON.")
        @OptionGroup var target: TargetOptions
        @Argument(help: "Where to write the JSON.") var path: String

        func run() throws {
            try apvt.run(json: false) {
                let platform = try Session.platform(target.platform)
                let data = try platform.rawRequest(AgentRequest(cmd: "swiftui-raw"), to: try Session.agent(platform, target.target))
                try data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) (\(data.count) bytes)")
                return 0
            }
        }
    }

    struct Methods: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the selectors a class has inside the app (for porting to a new OS).")
        @OptionGroup var target: TargetOptions
        @Argument(help: "Class name.") var className: String
        @Option(help: "Only selectors containing this.") var match: String?

        func run() throws {
            try apvt.run(json: false) {
                let platform = try Session.platform(target.platform)
                let data = try platform.rawRequest(AgentRequest(cmd: "methods", className: className, match: match), to: try Session.agent(platform, target.target))
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                (object?["methods"] as? [String] ?? []).forEach { print($0) }
                return 0
            }
        }
    }
}
