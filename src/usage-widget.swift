// AI Usage Tracker — an iPhone-style card that sits on the desktop, behind every app,
// showing how much of each Codex account's and Claude's usage window is spent.
// Built into "AI Usage Tracker.app" by install.sh.
//
// It reads NOTHING itself and never touches a credential. Every figure comes from two
// scripts installed beside its config in $AI_USAGE_TRACKER_HOME (~/.ai-usage-tracker):
//
//   statusline.py --json     live per-account Codex read; ALSO writes the live cache
//   work-mode.py  --json     Claude's own window and the resulting MODE
//
// That order is load-bearing: work-mode reuses statusline's live cache while it is
// inside LIVE_TTL, so one refresh tick costs one API turn per Codex account, not two.
//
//   usage-widget --dump          render once, print the card as text, exit
//   usage-widget --shot <path>   render once to a PNG (needs no Screen Recording)
//
// Adding an account never writes the account list before the sign-in has finished:
//
//   Codex   `codex login --device-auth` runs in the background (DeviceLogin). Its link and
//           one-time code become a message to forward (DeviceLoginWindow), so the owner
//           signs in in their own browser, on any device. Only exit 0 WITH an auth.json
//           appends the account — statusline.py reads auth.json directly.
//   Claude  Claude Code has no device-code login. Terminal runs `claude auth login`; its
//           link works in any browser and the page's code must come back to be pasted.
//           The launcher's exit status 0 is what appends the account.
//
//   usage-widget --device-login <label> <home>   the Codex add flow headless (for tests)
//   usage-widget --shot-login <path>             render the link window to a PNG
//   usage-widget --chip-from <sl.json> <wm.json> print the menu bar chip for saved output

import AppKit
import Darwin

// Each tick opens one real turn per Codex account. 300s = 36 turns/hour across three
// accounts, against weekly windows that move slowly. Do not shorten this casually.
let refreshInterval: TimeInterval = 300

let cardWidth: CGFloat = 300
let pad: CGFloat = 16
let showPanelNote = Notification.Name("io.github.av3ragejoe.ai-usage-tracker.show")

// One folder holds the scripts, both account lists and the cache. The environment override
// exists for the tests, so they never read or write a real account list.
let appHomeOverride: String? = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_HOME"]
    .flatMap { $0.isEmpty ? nil : $0 }
let appHome = appHomeOverride ?? (NSHomeDirectory() + "/.ai-usage-tracker")

// The account list statusline.py reads. Shared on purpose: adding a login here makes it
// appear in the status line and `ai-usage` too.
let accountsPath = appHome + "/codex-accounts.json"
let claudeAccountsPath = appHome + "/claude-accounts.json"

struct Account { var label: String; var home: String }  // home stored as "~/..."
struct ClaudeAccount { var label: String; var configDir: String }  // dir stored as "~/..."

let defaultClaudeAccount = ClaudeAccount(label: "Default", configDir: "~/.claude")

/// Hold one process-wide transaction lock through the read and atomic replace. Locking
/// only the final write still lets two menu/CLI edits read the same stale list and race.
func withAccountsLock<T>(_ path: String, _ body: () -> T?) -> T? {
    let fd = Darwin.open(path + ".lock", O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return nil }
    defer {
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }
    guard flock(fd, LOCK_EX) == 0 else { return nil }
    return body()
}

func loadAccounts() -> [Account] {
    guard let data = FileManager.default.contents(atPath: accountsPath),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let raw = root["accounts"] as? [[String: Any]] else { return [] }
    return raw.compactMap {
        guard let l = $0["label"] as? String, let h = $0["home"] as? String else { return nil }
        return Account(label: l, home: h)
    }
}

private func writeAccounts(_ accounts: [Account]) -> Bool {
    let payload = ["accounts": accounts.map { ["label": $0.label, "home": $0.home] }]
    guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                 options: [.prettyPrinted, .sortedKeys])
    else { return false }
    // Atomic: a session may be reading this file while the menu writes it.
    return (try? data.write(to: URL(fileURLWithPath: accountsPath), options: .atomic)) != nil
}

func saveAccounts(_ accounts: [Account]) -> Bool {
    withAccountsLock(accountsPath) { writeAccounts(accounts) } ?? false
}

func updateAccounts(_ edit: ([Account]) -> [Account]?) -> Bool {
    withAccountsLock(accountsPath) {
        guard let changed = edit(loadAccounts()) else { return false }
        return writeAccounts(changed)
    } ?? false
}

func expand(_ home: String) -> String {
    home.hasPrefix("~") ? NSHomeDirectory() + String(home.dropFirst()) : home
}

/// Account folders hold a login (auth.json) and session logs, so a folder this app creates
/// is owner-only (0700). An existing folder is left exactly as it is.
func makePrivateDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: expand(path),
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}

func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: expand(path)).resolvingSymlinksInPath().standardized.path
}

func loadClaudeAccounts() -> [ClaudeAccount] {
    guard let data = FileManager.default.contents(atPath: claudeAccountsPath),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let raw = root["accounts"] as? [[String: Any]] else { return [defaultClaudeAccount] }
    let accounts: [ClaudeAccount] = raw.compactMap {
        guard let label = $0["label"] as? String,
              let configDir = $0["config_dir"] as? String else { return nil }
        return ClaudeAccount(label: label, configDir: configDir)
    }
    return accounts.isEmpty ? [defaultClaudeAccount] : accounts
}

private func writeClaudeAccounts(_ accounts: [ClaudeAccount]) -> Bool {
    let payload = ["accounts": accounts.map {
        ["label": $0.label, "config_dir": $0.configDir]
    }]
    guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                 options: [.prettyPrinted, .sortedKeys])
    else { return false }
    // Atomic replacement happens before withAccountsLock releases the transaction lock.
    return (try? data.write(to: URL(fileURLWithPath: claudeAccountsPath),
                            options: .atomic)) != nil
}

func saveClaudeAccounts(_ accounts: [ClaudeAccount]) -> Bool {
    withAccountsLock(claudeAccountsPath) { writeClaudeAccounts(accounts) } ?? false
}

func updateClaudeAccounts(_ edit: ([ClaudeAccount]) -> [ClaudeAccount]?) -> Bool {
    withAccountsLock(claudeAccountsPath) {
        guard let changed = edit(loadClaudeAccounts()) else { return false }
        return writeClaudeAccounts(changed)
    } ?? false
}

func isDefaultClaudeAccount(_ account: ClaudeAccount) -> Bool {
    canonicalPath(account.configDir) == canonicalPath(defaultClaudeAccount.configDir)
}

/// POSIX single quotes make every byte literal except the quote itself, which must end
/// the quoted span, be escaped, then reopen it. Launchers embed user-entered paths and
/// labels because NSWorkspace cannot attach a per-launch environment to Terminal.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A GUI app does not inherit an interactive shell's PATH, so the usual install
/// locations are checked in order. UW_TOOL_DIR lets the shell tests swap in stub tools;
/// it is honoured only by the bare test binary, never inside the installed app, so an
/// environment variable can never choose which program receives a sign-in.
func resolveTool(_ name: String) -> String? {
    var dirs: [String] = []
    if Bundle.main.bundleIdentifier == nil,
       let testDir = ProcessInfo.processInfo.environment["UW_TOOL_DIR"], !testDir.isEmpty {
        dirs.append(testDir)
    }
    dirs += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct AuthLauncher { let scriptPath: String; let sentinelPath: String }

/// Write a private, one-use Terminal launcher. UUID names avoid account labels becoming
/// filenames, while 0700/0600 keep another local user from changing either handoff file.
func makeAuthLauncher(toolPath: String, environmentName: String, configDir: String,
                      product: String, label: String, action: String,
                      arguments: [String]) -> AuthLauncher? {
    let temp = NSTemporaryDirectory()
    let identifier = UUID().uuidString
    let path = temp + identifier + ".command"
    let sentinel = temp + identifier + ".status"
    let command = ([toolPath] + arguments).map(shellQuote).joined(separator: " ")
    let script = """
    #!/bin/sh
    printf '%s for %s account %s  —  %s=%s\\n' \
      \(shellQuote(action)) \(shellQuote(product)) \(shellQuote(label)) \
      \(shellQuote(environmentName)) \(shellQuote(configDir))
    echo
    \(environmentName)=\(shellQuote(expand(configDir))) \(command)
    code=$?
    echo
    if [ "$code" -eq 0 ]; then
      echo "Done. The widget will refresh automatically."
    else
      printf '%s exited %s.\\n' \(shellQuote(product)) "$code"
    fi
    echo "You can close this window."
    rm -f "$0"; printf '%s' "$code" > \(shellQuote(sentinel))
    """
    guard FileManager.default.createFile(atPath: sentinel, contents: Data(),
                                         attributes: [.posixPermissions: 0o600]) else {
        return nil
    }
    guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
        try? FileManager.default.removeItem(atPath: sentinel)
        return nil
    }
    guard (try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: path)) != nil else {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: sentinel)
        return nil
    }
    return AuthLauncher(scriptPath: path, sentinelPath: sentinel)
}

enum AppendResult { case saved, duplicate, failed }

/// Duplicate = same label or the same folder after ~ and symlinks, checked inside the
/// lock so two adds cannot both pass.
func appendAccount(_ account: Account) -> AppendResult {
    var duplicate = false
    let saved = updateAccounts { all in
        guard !all.contains(where: {
            $0.label == account.label || canonicalPath($0.home) == canonicalPath(account.home)
        }) else {
            duplicate = true
            return nil
        }
        return all + [account]
    }
    return duplicate ? .duplicate : saved ? .saved : .failed
}

func appendClaudeAccount(_ account: ClaudeAccount) -> AppendResult {
    var duplicate = false
    let saved = updateClaudeAccounts { all in
        guard !all.contains(where: {
            $0.label == account.label
                || canonicalPath($0.configDir) == canonicalPath(account.configDir)
        }) else {
            duplicate = true
            return nil
        }
        return all + [account]
    }
    return duplicate ? .duplicate : saved ? .saved : .failed
}

struct DeviceLink: Equatable { let url: String; let code: String; let minutes: Int }

/// Colour codes would otherwise end up inside the URL or the code.
func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
                           options: .regularExpression)
}

/// `codex login --device-auth` prints (codex-cli 0.153, read from the binary's strings):
///   1. Open this link in your browser and sign in to your account
///      https://auth.openai.com/codex/device
///   2. Enter this one-time code (expires in 15 minutes)
///      ABCD-12345
/// Take the first https URL after step 1 and the first non-blank line after step 2.
func parseDeviceLink(_ output: String) -> DeviceLink? {
    let lines = stripANSI(output).components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    func index(of marker: String) -> Int? {
        lines.firstIndex { $0.range(of: marker, options: .caseInsensitive) != nil }
    }
    guard let linkLine = index(of: "open this link"),
          let codeLine = index(of: "one-time code") else { return nil }
    let url = lines[(linkLine + 1)...].lazy.compactMap { line -> String? in
        line.range(of: "https://[^\\s]+", options: .regularExpression).map { String(line[$0]) }
    }.first
    let code = lines[(codeLine + 1)...].first { !$0.isEmpty }
    guard let url, let code, code.count >= 6,
          code.range(of: "^[A-Za-z0-9]{3,}(-[A-Za-z0-9]{3,})*$",
                     options: .regularExpression) != nil else { return nil }
    let minutes = lines[codeLine].range(of: "[0-9]+(?= minutes)", options: .regularExpression)
        .flatMap { Int(lines[codeLine][$0]) } ?? 15
    return DeviceLink(url: url, code: code, minutes: minutes)
}

enum DeviceLoginOutcome: Equatable {
    case signedIn, cancelled, expired, noAuthFile, failed(String)

    var canRetry: Bool { self != .signedIn && self != .cancelled }

    func message(label: String, home: String, adding: Bool) -> String {
        let nothing = adding ? " Nothing was added." : " The existing login was left as it was."
        switch self {
        case .signedIn:
            return adding ? "Signed in. Account \(label) is now on your widget."
                          : "Signed in. Account \(label) has a fresh login."
        case .cancelled:
            return "Cancelled." + nothing
        case .expired:
            return "The code expired before the sign-in finished. Start again for a new code."
                + nothing
        case .noAuthFile:
            return "Codex reported success but wrote no auth.json in \(home), and that file is"
                + " the only place the widget can read an account from." + nothing
        case .failed(let why):
            return "Sign-in did not finish: \(why)" + nothing
        }
    }
}

func deviceLoginOutcome(status: Int32, cancelled: Bool, timedOut: Bool, authWritten: Bool,
                        output: String) -> DeviceLoginOutcome {
    if timedOut { return .expired }
    if cancelled { return .cancelled }
    if status == 0 { return authWritten ? .signedIn : .noAuthFile }
    let lines = stripANSI(output).components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    // The prompt itself says "expires in"; only an error says "expired".
    if lines.contains(where: { $0.range(of: "expired", options: .caseInsensitive) != nil }) {
        return .expired
    }
    return .failed(lines.last.map { String($0.prefix(200)) }
                   ?? "Codex exited \(status) without saying why.")
}

/// `codex login --device-auth` in the background, so the sign-in can happen in someone
/// else's browser. The widget reads only what Codex prints for a person to see — a public
/// URL and a one-time pairing code. The token goes from Codex straight into auth.json.
final class DeviceLogin {
    /// File storage pinned: statusline.py reads auth.json directly, so a login that went
    /// to the Keychain instead would add an account the widget can never read.
    static let arguments = ["login", "--device-auth", "-c", "cli_auth_credentials_store=\"file\""]

    let home: String
    var onLink: ((DeviceLink) -> Void)?
    var onExit: ((DeviceLoginOutcome) -> Void)?
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private let callbackQueue: DispatchQueue
    private var buffer = Data()
    private var announced = false
    private var cancelled = false
    private var timedOut = false

    init(toolPath: String, home: String, callbackQueue: DispatchQueue) {
        self.home = home
        self.callbackQueue = callbackQueue
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = DeviceLogin.arguments
        // npm's `codex` is `#!/usr/bin/env node`, so its own directory (where Homebrew also
        // puts node) must be on PATH: the widget itself runs with launchd's bare PATH.
        let toolDir = URL(fileURLWithPath: toolPath).deletingLastPathComponent().path
        process.environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": expand(home),
            "PATH": ([toolDir] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
                .joined(separator: ":"),
            "NO_COLOR": "1",
            "TERM": "dumb",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    /// Everything Codex has printed so far: the link text, then any error.
    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func start() -> Bool {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { self?.append(chunk) }
        }
        process.terminationHandler = { [self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            append(pipe.fileHandleForReading.readDataToEndOfFile())
            lock.lock()
            let (wasCancelled, wasTimedOut) = (cancelled, timedOut)
            lock.unlock()
            let outcome = deviceLoginOutcome(
                status: finished.terminationStatus, cancelled: wasCancelled, timedOut: wasTimedOut,
                authWritten: FileManager.default.fileExists(atPath: expand(home) + "/auth.json"),
                output: output)
            callbackQueue.async { self.onExit?(outcome) }
            finished.terminationHandler = nil
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            return false
        }
        // Codex gives up by itself when the code expires; this only guarantees the window
        // can never wait forever if it does not.
        callbackQueue.asyncAfter(deadline: .now() + 16 * 60) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            self.process.terminate()
        }
        return true
    }

    /// SIGTERM: codex.js forwards it to the native binary and mirrors its exit.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        var link: DeviceLink?
        if !announced, let parsed = parseDeviceLink(String(decoding: buffer, as: UTF8.self)) {
            link = parsed
            announced = true
        }
        lock.unlock()
        if let link { callbackQueue.async { self.onLink?(link) } }
    }
}

/// The text the user forwards. Written for the account owner, who has seen none of this.
func codexShareMessage(_ link: DeviceLink) -> String {
    """
    Hi! Please link your ChatGPT account to my Codex setup. It takes about a minute.

    First, once only: open chatgpt.com in a web browser (this setting is not in the \
    phone app), click your profile picture → Settings → Security, and turn on \
    "Device code authorization for Codex". (On a work or school account, your \
    workspace admin has to allow it.)

    1. Open this link in any browser: \(link.url)
    2. Sign in with your own ChatGPT account.
    3. Enter this code: \(link.code)
    4. Approve the request.

    That's all. You don't need to send anything back. The code expires in \(link.minutes) minutes.
    """
}

/// --device-login: the same DeviceLogin and the same append rule as the window, so the
/// shell test proves the list is written only after a finished sign-in.
func deviceLoginCLI(_ account: Account) -> Bool {
    func say(_ line: String) { print(line); fflush(stdout) }
    if loadAccounts().contains(where: {
        $0.label == account.label || canonicalPath($0.home) == canonicalPath(account.home)
    }) {
        say("NOT-ADDED\talready listed")
        return false
    }
    guard let toolPath = resolveTool("codex") else {
        say("NOT-ADDED\tcodex is not installed")
        return false
    }
    try? makePrivateDirectory(account.home)
    let queue = DispatchQueue(label: "device-login")
    let done = DispatchSemaphore(value: 0)
    var added = false
    let login = DeviceLogin(toolPath: toolPath, home: account.home, callbackQueue: queue)
    login.onLink = { say("LINK\t\($0.url)\t\($0.code)\t\($0.minutes)") }
    login.onExit = { outcome in
        if outcome == .signedIn {
            switch appendAccount(account) {
            case .saved:
                added = true
                say("ADDED\t\(account.label)")
            case .duplicate: say("NOT-ADDED\tlisted meanwhile")
            case .failed: say("NOT-ADDED\tcould not write the account list")
            }
        } else {
            say("NOT-ADDED\t" + outcome.message(label: account.label, home: account.home,
                                                adding: true))
        }
        done.signal()
    }
    guard login.start() else {
        say("NOT-ADDED\tcodex could not be started")
        return false
    }
    done.wait()
    return added
}

/// Hands a Codex device-code link to whoever owns the account. Non-modal, so the widget
/// keeps refreshing and the user can switch apps to send the message.
final class DeviceLoginWindow: NSObject, NSWindowDelegate {
    let label: String
    let home: String
    let adding: Bool
    let login: DeviceLogin
    var onClosed: (() -> Void)?
    var onRetry: (() -> Void)?
    private let window: NSWindow
    private let scroll: NSScrollView
    private let messageView: NSTextView
    private let status = NSTextField(wrappingLabelWithString: "Asking Codex for a sign-in link…")
    private let copyButton = NSButton(title: "Copy message", target: nil, action: nil)
    private let openButton = NSButton(title: "Open link here", target: nil, action: nil)
    private let retryButton = NSButton(title: "Start again", target: nil, action: nil)
    private let closeButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var link: DeviceLink?
    private var finished = false

    init(label: String, home: String, adding: Bool, login: DeviceLogin) {
        self.label = label
        self.home = home
        self.adding = adding
        self.login = login
        scroll = NSTextView.scrollableTextView()
        messageView = scroll.documentView as! NSTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = adding ? "Add Codex account \(label)" : "Sign in Codex account \(label)"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let intro = NSTextField(wrappingLabelWithString:
            "Send the message below to the person whose ChatGPT account this is. They can use"
            + " any browser, on any device."
            + (adding ? " Account \(label) appears on your widget only once they finish." : ""))
        intro.textColor = .secondaryLabelColor
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.font = .systemFont(ofSize: 13)
        messageView.textContainerInset = NSSize(width: 6, height: 8)
        messageView.string = "Waiting for Codex to hand out a code…"
        scroll.borderType = .bezelBorder

        for (button, action) in [(copyButton, #selector(copyMessage)),
                                 (openButton, #selector(openLink)),
                                 (retryButton, #selector(retry)),
                                 (closeButton, #selector(closeOrCancel))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        copyButton.isEnabled = false
        openButton.isEnabled = false
        openButton.toolTip = "For your own account: opens the link in this Mac's browser."
        retryButton.isHidden = true
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.setViews([copyButton, openButton], in: .leading)
        buttons.setViews([retryButton, closeButton], in: .trailing)
        let stack = NSStackView(views: [intro, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        let width: CGFloat = 440
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: width),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            status.widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalToConstant: width),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        // If Codex prints something the parser does not recognise, show that text instead
        // of waiting on a link that will never be found.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.link == nil, !self.finished else { return }
            let raw = stripANSI(self.login.output).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            self.messageView.string = raw
            self.copyButton.isEnabled = true
            self.status.stringValue = "Could not pick the link out of Codex's text, so it is shown"
                + " as printed: send them the link and code in it. Still waiting for the sign-in."
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is never frontmost
        window.makeKeyAndOrderFront(nil)
    }

    func show(_ link: DeviceLink) {
        guard !finished else { return }
        self.link = link
        messageView.string = codexShareMessage(link)
        copyButton.isEnabled = true
        openButton.isEnabled = URL(string: link.url)?.scheme == "https"
        let expiry = DateFormatter.localizedString(
            from: Date().addingTimeInterval(TimeInterval(link.minutes * 60)),
            dateStyle: .none, timeStyle: .short)
        status.stringValue = "Waiting for them to finish. The code expires at \(expiry)."
    }

    func finish(ok: Bool, text: String, canRetry: Bool) {
        finished = true
        status.stringValue = (ok ? "✓ " : "") + text
        copyButton.isEnabled = false
        openButton.isEnabled = false
        retryButton.isHidden = !canRetry
        closeButton.title = ok ? "Done" : "Close"
        closeButton.keyEquivalent = "\r"
        window.orderFrontRegardless()  // show the result without stealing focus
    }

    /// For --shot-login: the window's own frame view (title bar and background included,
    /// so light-on-dark labels stay legible), drawn without Screen Recording.
    func pngData() -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messageView.string, forType: .string)
        copyButton.title = "Copied"
    }

    @objc private func openLink() {
        guard let link, let url = URL(string: link.url), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func retry() {
        let again = onRetry
        window.close()
        again?()
    }

    @objc private func closeOrCancel() {
        if finished { window.close() } else { login.cancel() }
    }

    func windowWillClose(_: Notification) {
        if !finished { login.cancel() }  // closing mid-sign-in is a cancel: nothing is added
        onClosed?()
    }
}

let dumpMode = CommandLine.arguments.contains("--dump")
let shotPath: String? = CommandLine.arguments.firstIndex(of: "--shot")
    .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
let iconPath: String? = CommandLine.arguments.firstIndex(of: "--icon")
    .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
let checkMenusMode = CommandLine.arguments.contains("--check-menus")
let loginShotPath: String? = CommandLine.arguments.firstIndex(of: "--shot-login")
    .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
// --chip-from <statusline.json> <work-mode.json>: run build() on saved output and print
// each chip segment with its colour, so every branch is testable without the network.
let chipFrom: [String]? = CommandLine.arguments.firstIndex(of: "--chip-from")
    .flatMap { $0 + 2 < CommandLine.arguments.count
        ? Array(CommandLine.arguments[($0 + 1)...($0 + 2)]) : nil }
// Headless account edits: the same load/save the Accounts menu uses, so a test can
// prove statusline.py and this file agree about codex-accounts.json.
//   --accounts                     list them
//   --add-account <label> <home>   append (no login; use the menu for that)
//   --remove-account <label>       drop it, leaving the folder on disk
func accountsCLI(_ args: [String]) -> Bool {
    func value(_ flag: String, _ n: Int) -> [String]? {
        guard let i = args.firstIndex(of: flag), i + n < args.count else { return nil }
        return Array(args[(i + 1)...(i + n)])
    }
    if args.contains("--resolve-tools") {
        for name in ["codex", "claude"] {
            print("\(name)\t\(resolveTool(name) ?? "MISSING")")
        }
        return true
    }
    // Test seam: make the exact launcher the menus use, but do not touch AppKit or open
    // Terminal. The shell test executes it and measures quoting plus both exit statuses.
    if let v = value("--make-auth-launcher", 4) {
        let (tool, action, label, configDir) = (v[0], v[1], v[2], v[3])
        let environmentName: String
        let product: String
        let actionText: String
        let arguments: [String]
        switch (tool, action) {
        case ("codex", "login"):
            (environmentName, product, actionText, arguments) =
                ("CODEX_HOME", "Codex", "Signing in", ["login"])
        case ("claude", "login"):
            (environmentName, product, actionText, arguments) =
                ("CLAUDE_CONFIG_DIR", "Claude", "Re-authenticating", ["auth", "login"])
        case ("claude", "logout"):
            (environmentName, product, actionText, arguments) =
                ("CLAUDE_CONFIG_DIR", "Claude", "Signing out", ["auth", "logout"])
        default:
            FileHandle.standardError.write("unsupported tool/action\n".data(using: .utf8)!)
            exit(1)
        }
        guard let toolPath = resolveTool(tool) else {
            FileHandle.standardError.write("\(tool) is not installed\n".data(using: .utf8)!)
            exit(1)
        }
        guard let launcher = makeAuthLauncher(toolPath: toolPath,
                                              environmentName: environmentName,
                                              configDir: configDir, product: product,
                                              label: label, action: actionText,
                                              arguments: arguments) else { exit(1) }
        print("\(launcher.scriptPath)\t\(launcher.sentinelPath)")
        return true
    }
    if args.contains("--accounts") {
        for a in loadAccounts() { print("\(a.label)\t\(a.home)") }
        return true
    }
    if let v = value("--add-account", 2) {
        switch appendAccount(Account(label: v[0], home: v[1])) {
        case .saved: return true
        case .duplicate:
            FileHandle.standardError.write("already listed\n".data(using: .utf8)!)
            exit(1)
        case .failed: exit(1)
        }
    }
    // The Codex add flow minus the window: prints LINK<TAB>url<TAB>code<TAB>minutes once
    // Codex shows it, then ADDED or NOT-ADDED<TAB>why. Only ADDED writes the list.
    if let v = value("--device-login", 2) {
        exit(deviceLoginCLI(Account(label: v[0], home: v[1])) ? 0 : 1)
    }
    if let v = value("--remove-account", 1) {
        guard updateAccounts({ all in all.filter { $0.label != v[0] } }) else { exit(1) }
        return true
    }
    if args.contains("--claude-accounts") {
        for a in loadClaudeAccounts() { print("\(a.label)\t\(a.configDir)") }
        return true
    }
    if let v = value("--add-claude-account", 2) {
        switch appendClaudeAccount(ClaudeAccount(label: v[0], configDir: v[1])) {
        case .saved: return true
        case .duplicate:
            FileHandle.standardError.write("already listed\n".data(using: .utf8)!)
            exit(1)
        case .failed: exit(1)
        }
    }
    if let v = value("--remove-claude-account", 1) {
        var refusedDefault = false
        let saved = updateClaudeAccounts { all in
            guard let target = all.first(where: { $0.label == v[0] }) else { return all }
            guard !isDefaultClaudeAccount(target) else {
                refusedDefault = true
                return nil
            }
            let remaining = all.filter { $0.label != v[0] }
            return remaining.isEmpty ? [defaultClaudeAccount] : remaining
        }
        guard !refusedDefault else {
            FileHandle.standardError.write("the default Claude account cannot be removed\n"
                .data(using: .utf8)!)
            exit(1)
        }
        guard saved else { exit(1) }
        return true
    }
    return false
}

let headless = dumpMode || shotPath != nil || iconPath != nil || checkMenusMode
    || loginShotPath != nil || chipFrom != nil

// MARK: - palette
// Follows the system appearance the way an iOS widget does, rather than pinning one
// scheme: the first build pinned dark and washed out on a light desktop.

func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
}
let cardBG = dyn(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97),
                 NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97))
let primary = dyn(NSColor(white: 0.10, alpha: 1), NSColor(white: 0.97, alpha: 1))
let secondary = dyn(NSColor(white: 0.45, alpha: 1), NSColor(white: 0.62, alpha: 1))
let track = dyn(NSColor(white: 0.90, alpha: 1), NSColor(white: 0.24, alpha: 1))
let hairline = dyn(NSColor(white: 0.88, alpha: 1), NSColor(white: 0.22, alpha: 1))
let green = NSColor(srgbRed: 0.20, green: 0.72, blue: 0.35, alpha: 1)
let amber = NSColor(srgbRed: 0.95, green: 0.62, blue: 0.07, alpha: 1)
let red = NSColor(srgbRed: 0.91, green: 0.26, blue: 0.21, alpha: 1)

func colour(_ pct: Double, warn: Double, alert: Double) -> NSColor {
    if pct >= alert { return red }
    if pct >= warn { return amber }
    return green
}

/// A percentage from the scripts' JSON, finite and clamped to 0...100, or nil. Every figure
/// originates outside this program (HTTP headers, log files), and Int(Double) traps on a
/// non-finite or huge value — one bad header must not crash the widget.
func cleanPct(_ raw: Any?) -> Double? {
    guard let value = raw as? Double, value.isFinite else { return nil }
    return min(100, max(0, value))
}

// "in 5d 21h" — shorter than a wall-clock stamp, and the question actually being asked.
func resetText(_ epoch: Double?) -> String {
    // 4102444800 = 2100-01-01: anything later (or non-finite) is garbage, not a reset time.
    guard let epoch, epoch.isFinite, epoch > 0, epoch < 4_102_444_800 else { return "" }
    let left = Int(epoch - Date().timeIntervalSince1970)
    if left <= 0 { return "resetting" }
    let (d, h, m) = (left / 86400, (left % 86400) / 3600, (left % 3600) / 60)
    if d > 0 { return "in \(d)d \(h)h" }
    if h > 0 { return "in \(h)h \(m)m" }
    return "in \(m)m"
}

/// Run a python script and decode its stdout as JSON. Returns nil on any failure — a
/// widget that cannot read is one that says so, never one that shows a guess.
func runJSON(_ script: String) -> [String: Any]? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script, "--json"]
    // Explicit /usr/bin/python3 and a clean env: whichever virtualenv happens to be
    // active in a login shell must not decide whether the widget works.
    var env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    if let appHomeOverride { env["AI_USAGE_TRACKER_HOME"] = appHomeOverride }
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - model

struct Bar {
    let name: String       // "A", "Claude"
    let detail: String     // "~/.codex · 7d"
    let pct: Double?       // nil = unreadable
    let note: String       // "in 5d 21h"
    let stale: Bool
}

struct Model {
    var codex: [Bar] = []
    var claude: [Bar] = []
    var mode = "UNKNOWN"
    var why = ""
    var warn = 60.0
    var alert = 85.0
}

// MARK: - the card

/// The panel never becomes key (it must not steal focus), so without this every click
/// is swallowed as a would-be activation click and the buttons appear dead.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CardView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var model = Model()
    private var drawing = false  // helpers honour this, so a block can be measured silently
    override var isFlipped: Bool { true }  // top-down y; every offset below reads forwards

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        cardBG.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        layout(draw: true)
    }

    func fittingHeight() -> CGFloat { layout(draw: false) }

    // One pass does both measuring and drawing, so the panel height can never disagree
    // with what is actually painted into it.
    @discardableResult
    private func layout(draw: Bool) -> CGFloat {
        drawing = draw
        let w = cardWidth - pad * 2
        var y = pad

        func text(_ s: String, _ font: NSFont, _ colour: NSColor,
                  x: CGFloat = pad, width: CGFloat? = nil,
                  align: NSTextAlignment = .left, lines: Int = 1) -> CGFloat {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] =
                [.font: font, .foregroundColor: colour, .paragraphStyle: style]
            let box = NSSize(width: width ?? (cardWidth - x - pad),
                             height: CGFloat(lines) * (font.pointSize + 5))
            let a = NSAttributedString(string: s, attributes: attrs)
            let h = ceil(a.boundingRect(with: box, options: .usesLineFragmentOrigin).height)
            if drawing { a.draw(with: NSRect(x: x, y: y, width: box.width, height: h),
                                options: .usesLineFragmentOrigin) }
            return h
        }

        func bar(_ pct: Double, _ colour: NSColor) {
            guard drawing else { return }
            let r = NSRect(x: pad, y: y, width: w, height: 6)
            track.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            guard pct > 0 else { return }  // an empty window is an empty track, not a nub
            let filled = max(6, w * CGFloat(min(100, max(0, pct))) / 100)
            colour.setFill()
            NSBezierPath(roundedRect: NSRect(x: pad, y: y, width: filled, height: 6),
                         xRadius: 3, yRadius: 3).fill()
        }

        func section(_ title: String) {
            y += text(title, .systemFont(ofSize: 10, weight: .semibold), secondary)
            y += 6
        }

        func rows(_ bars: [Bar]) {
            for b in bars {
                _ = text(b.name, .systemFont(ofSize: 13, weight: .semibold), primary)
                if let pct = b.pct {
                    _ = text(String(format: "%d%%", Int(pct.rounded())) + (b.stale ? "*" : ""),
                             .monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                             colour(pct, warn: model.warn, alert: model.alert),
                             align: .right)
                } else {
                    _ = text("—", .systemFont(ofSize: 13, weight: .bold), red, align: .right)
                }
                y += 18
                bar(b.pct ?? 0, b.pct.map { colour($0, warn: model.warn, alert: model.alert) } ?? track)
                y += 6 + 4
                let tail = [b.detail, b.note].filter { !$0.isEmpty }.joined(separator: " · ")
                if !tail.isEmpty {
                    y += text(tail, .systemFont(ofSize: 10, weight: .regular), secondary)
                }
                y += 8
            }
        }

        // header — the right-hand third is reserved for the +, ⋯ and ✕ buttons
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")  // else the 12/24-hour preference wins
        clock.dateFormat = "HH:mm"
        _ = text("AI USAGE  ·  " + clock.string(from: Date()),
                 .systemFont(ofSize: 10, weight: .bold), secondary, width: cardWidth - pad - 88)
        y += 18

        rows(model.codex)

        // The verdict, not just the figures: which account to dispatch to is the reason
        // this readout exists. statusline.py owns the rule; the card only lays it out.
        if drawing {
            hairline.setFill()
            NSRect(x: pad, y: y, width: w, height: 1).fill()
        }
        y += 13

        section("CLAUDE")
        rows(model.claude)

        // footer: the MODE pill, then the sentence behind it
        let modeColour = model.mode == "NORMAL" ? green : (model.mode == "UNKNOWN" ? red : amber)
        if drawing {
            let size = NSAttributedString(string: model.mode, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold)]).size()
            let r = NSRect(x: pad, y: y, width: ceil(size.width) + 14, height: 16)
            modeColour.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            NSAttributedString(string: model.mode, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: modeColour,
            ]).draw(at: NSPoint(x: pad + 7, y: y + 3))
        }
        y += 16 + 6
        if !model.why.isEmpty {
            y += text(model.why, .systemFont(ofSize: 10, weight: .regular), secondary, lines: 2)
        }
        return y + pad
    }
}

// MARK: - app

/// One card on one display. With a laptop plus an external monitor the widget belongs on
/// both, so there is a panel per screen rather than one panel that has to guess which
/// display is being looked at.
final class CardPanel {
    let displayID: CGDirectDisplayID
    let card = CardView()
    let close = FirstMouseButton()
    let addButton = FirstMouseButton()
    let moreButton = FirstMouseButton()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)

    // Keyed by display, so dragging one monitor's card does not move another's.
    private var autosaveName: String { "codexUsageCard-\(displayID)" }
    private var positioned = false

    init(displayID: CGDirectDisplayID, owner: Widget) {
        self.displayID = displayID
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 400)
        panel.contentView = card
        panel.isOpaque = false          // the corners are rounded by the card, not the frame
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.setFrameAutosaveName(autosaveName)
        // AppKit stores the frame under this defaults key, and its presence is the only
        // way to tell "restored" from "never placed" — the frame itself cannot say, since
        // an unplaced panel legitimately sits at 0,0 (which briefly parked a card in the
        // bottom-left corner). Registering the name only makes AppKit SAVE the frame;
        // setFrameUsingName is what loads it.
        positioned = UserDefaults.standard.object(forKey: "NSWindow Frame " + autosaveName) != nil
        panel.setFrameUsingName(autosaveName)

        for (button, symbol, help, action) in [
            (addButton, "plus.circle.fill", "Add a Codex account", #selector(Widget.addAccount)),
            (moreButton, "ellipsis.circle.fill", "Accounts", #selector(Widget.showAccountsMenu(_:))),
            (close, "xmark.circle.fill", "Close (reopen from Spotlight)", #selector(Widget.hidePanel)),
        ] {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = secondary
            button.toolTip = help
            button.target = owner
            button.action = action
            card.addSubview(button)
        }
        layoutButtons()
    }

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    /// True only when the saved frame still lands on this card's own display. A frame
    /// restored from a different monitor layout is worse than no frame at all.
    var isPlaced: Bool {
        guard positioned, let screen else { return false }
        return screen.visibleFrame.intersects(panel.frame)
    }

    func place() {
        guard let v = screen?.visibleFrame else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - panel.frame.width - 24, y: v.maxY - 24))
        panel.saveFrame(usingName: autosaveName)
        positioned = true
    }

    func applyLevel(onDesktop: Bool) {
        // Above the wallpaper, below every app — the iPhone home-screen behaviour.
        //
        // +1 is load-bearing (found 2026-09-06: the card could not be clicked at all).
        // Finder's own desktop window sits at EXACTLY kCGDesktopIconWindowLevel and spans
        // the whole screen, so a panel on that level is contested and Finder takes the
        // clicks. One level up still leaves us ~2.1 billion below kCGNormalWindowLevel,
        // so nothing about "behind every app" changes.
        panel.level = onDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    /// Right-aligned in the header, in reading order: add, accounts, close.
    func layoutButtons() {
        for (i, button) in [addButton, moreButton, close].reversed().enumerated() {
            button.frame = NSRect(x: cardWidth - 26 - CGFloat(i) * 21, y: 10, width: 17, height: 17)
        }
    }

    func apply(_ model: Model) {
        card.model = model
        let height = card.fittingHeight()
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(NSSize(width: cardWidth, height: height))
        panel.setFrameTopLeftPoint(topLeft)  // grow downwards, keeping the header put
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: height)
        layoutButtons()
        card.needsDisplay = true
        if !isPlaced { place() }
    }

    func show() {
        if !isPlaced { place() }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

final class Widget: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panels: [CGDirectDisplayID: CardPanel] = [:]
    var model = Model()
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu?
    var timer: Timer?
    var completionSources: [String: DispatchSourceFileSystemObject] = [:]
    var deviceLogins: [String: DeviceLoginWindow] = [:]  // keyed by canonical CODEX_HOME
    var busy = false
    var hidden = false
    var chipText = ""  // the menu bar title as text, so --dump can show it headless
    var chipSegments: [(String, NSColor)] = []  // the same, segment by segment (--chip-from)

    // It belongs on the desktop, behind the apps, like an iPhone widget.
    var onDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: "onDesktop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "onDesktop")
            panels.values.forEach { $0.applyLevel(onDesktop: newValue) }
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: ["onDesktop": true])
        syncScreens()
        if let path = iconPath {  // build-time only: draw the app icon and exit
            writeIcon(path)
            exit(0)
        }
        if headless {
            if let path = loginShotPath {  // the link window only: no fetch, no Codex
                loginShot(path)
                exit(0)
            }
            if let files = chipFrom {
                func load(_ path: String) -> [String: Any]? {
                    FileManager.default.contents(atPath: path)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                }
                build(codex: load(files[0]), mode: load(files[1]))
                let names = [(green, "green"), (amber, "amber"), (red, "red")]
                print(chipSegments.map { segment in
                    segment.0 + ":" + (names.first { $0.0 === segment.1 }?.1 ?? "?")
                }.joined(separator: " "))
                exit(0)
            }
            if checkMenusMode {
                // Unlike --dump, this path deliberately builds the real status item and
                // its nested account menus before printing their structured metadata.
                buildStatusItem()
                checkMenus()
                exit(0)
            }
            fetch(sync: true)
            if dumpMode { dumpText() }
            if let path = shotPath { shot(path) }
            exit(0)
        }
        buildStatusItem()
        fetch(sync: false)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetch(sync: false)
        }
        timer?.tolerance = 30  // let the OS coalesce the wake-up; nothing here is time-critical
        // A 300s timer says nothing about the eight hours the lid was shut.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.fetch(sync: false) }
        // Launching the app again from Spotlight re-opens a closed card. Launch Services
        // usually just reopens this instance, but a second copy would post this instead.
        DistributedNotificationCenter.default().addObserver(
            forName: showPanelNote, object: nil, queue: .main
        ) { [weak self] _ in self?.showPanel() }
        // Plugging a monitor in or out adds or drops its card, and re-places any card
        // whose saved frame no longer lands on its own display.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.syncScreens() }
    }

    /// Spotlight / Finder launch of an already-running accessory app lands here.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    /// Make the set of cards match the set of displays. Called at launch and whenever a
    /// monitor is connected or disconnected.
    func syncScreens() {
        // uint32Value IS a CGDirectDisplayID; no conversion needed.
        let live: Set<CGDirectDisplayID> = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })

        for id in panels.keys where !live.contains(id) {
            panels.removeValue(forKey: id)?.panel.orderOut(nil)
        }
        for id in live where panels[id] == nil {
            let cardPanel = CardPanel(displayID: id, owner: self)
            cardPanel.applyLevel(onDesktop: onDesktop)
            cardPanel.apply(model)
            panels[id] = cardPanel
            if !hidden && !headless { cardPanel.show() }
        }
        // A card whose display changed resolution can be left hanging off the edge.
        for cardPanel in panels.values where !cardPanel.isPlaced { cardPanel.place() }
    }

    @objc func showPanel() {
        hidden = false
        syncScreens()
        panels.values.forEach { $0.show() }
    }

    @objc func hidePanel() {
        hidden = true
        panels.values.forEach { $0.hide() }
    }

    @objc func resetPositions() {
        panels.values.forEach { $0.place() }
        showPanel()
    }

    @objc func showAccountsMenu(_ sender: NSButton) {
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is never frontmost
        accountsMenu().popUp(positioning: nil,
                             at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func buildStatusItem() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show widget", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Reset card positions",
                     action: #selector(resetPositions), keyEquivalent: "").target = self
        let pin = menu.addItem(withTitle: "Keep behind other windows",
                               action: #selector(toggleDesktop), keyEquivalent: "")
        pin.target = self
        pin.state = onDesktop ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accounts", action: nil, keyEquivalent: "").submenu = accountsMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusMenu = menu
        // --check-menus needs the exact menu tree but must not register a visible macOS
        // status item; the command-line verifier has no app bundle or UI lifecycle.
        guard !checkMenusMode else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without an autosave name macOS re-places the chip at the leftmost free slot on
        // every restart. On a notched MacBook Pro the status area right of the notch
        // (x 956…1728 here) fills up long before the items run out, so the leftmost slot
        // is BEHIND the notch — the chip renders perfectly and is physically invisible.
        // Found 2026-09-18: the chip was drawing "A100 B6 C11" at x=798..892 inside a
        // notch spanning 771…956. An autosave name pins it where it was last placed.
        statusItem.autosaveName = "codexUsageChip"
        statusItem.button?.title = "…"
        statusItem.menu = menu
    }

    func accountsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("accounts")
        menu.delegate = self
        populateAccountsMenu(menu)
        return menu
    }

    func populateAccountsMenu(_ menu: NSMenu) {
        // The ⋯ button is the card's only menu, so the refresh lives here too — reaching
        // the menu bar for it defeats the point of having the card in front of you.
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let codexHeader = menu.addItem(withTitle: "Codex", action: nil, keyEquivalent: "")
        codexHeader.isEnabled = false
        for (i, a) in loadAccounts().enumerated() {
            let item = menu.addItem(withTitle: "\(a.label)   \(a.home)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, action) in [("Send sign-in link…", #selector(sendLoginLink(_:))),
                                    ("Log in on this Mac…", #selector(loginAccount(_:))),
                                    ("Reveal folder in Finder", #selector(revealAccount(_:))),
                                    ("Remove…", #selector(removeAccount(_:)))] {
                let entry = sub.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.tag = i
                if action == #selector(loginAccount(_:)) || action == #selector(sendLoginLink(_:)),
                   resolveTool("codex") == nil {
                    entry.isEnabled = false
                    entry.toolTip = "Install Codex first: npm install -g @openai/codex"
                }
            }
            item.submenu = sub
        }
        menu.addItem(.separator())
        let claudeHeader = menu.addItem(withTitle: "Claude", action: nil, keyEquivalent: "")
        claudeHeader.isEnabled = false
        for (i, a) in loadClaudeAccounts().enumerated() {
            let item = menu.addItem(withTitle: "\(a.label)   \(a.configDir)",
                                    action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let login = sub.addItem(withTitle: "Re-authenticate…",
                                    action: #selector(loginClaudeAccount(_:)), keyEquivalent: "")
            login.target = self
            login.tag = i
            let signOut = sub.addItem(withTitle: "Sign out…",
                                      action: #selector(signOutClaudeAccount(_:)), keyEquivalent: "")
            signOut.target = self
            signOut.tag = i
            for entry in [login, signOut] where resolveTool("claude") == nil {
                entry.isEnabled = false
                entry.toolTip = "Install Claude Code first: npm install -g @anthropic-ai/claude-code"
            }
            let reveal = sub.addItem(withTitle: "Reveal folder",
                                     action: #selector(revealClaudeAccount(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.tag = i
            let removeTitle = isDefaultClaudeAccount(a)
                ? "Remove… (default account cannot be removed)" : "Remove…"
            let remove = sub.addItem(withTitle: removeTitle,
                                     action: #selector(removeClaudeAccount(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = i
            remove.isEnabled = !isDefaultClaudeAccount(a)
            item.submenu = sub
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Codex account…",
                     action: #selector(addAccount), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Claude account…",
                     action: #selector(addClaudeAccount), keyEquivalent: "").target = self
    }

    /// Menus are cheap compared with one usage fetch, so rebuild just before display as
    /// a backstop for account edits made by the CLI while the widget stays running.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "accounts" else { return }
        menu.removeAllItems()
        populateAccountsMenu(menu)
    }

    /// Rebuild the menu and re-read, so a change shows up without waiting for the timer.
    func accountsChanged() {
        rebuildAccountsMenus()
        fetch(sync: false)
    }

    func rebuildAccountsMenus() {
        statusMenu?.item(withTitle: "Accounts")?.submenu = accountsMenu()
    }

    private func alert(_ message: String, _ info: String, style: NSAlert.Style = .informational) -> NSAlert {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is never frontmost
        return a
    }

    /// Nothing is written to codex-accounts.json here. The link window appends the account
    /// only once Codex has finished the sign-in, so a half-done add never reaches the card,
    /// the status line or a dispatch decision.
    @objc func addAccount() {
        let existing = loadAccounts()
        let pending = deviceLogins.values.filter { $0.adding }
        // Next free letter, next free ~/.codex-altN — both just suggestions in the field.
        let used = Set(existing.map { $0.label } + pending.map { $0.label })
        let label = (0..<26).map { String(UnicodeScalar(65 + $0)!) }.first { !used.contains($0) } ?? "X"
        var suffix = 3
        let homes = Set((existing.map { $0.home } + pending.map { $0.home }).map(canonicalPath))
        while homes.contains(canonicalPath("~/.codex-alt\(suffix)")) { suffix += 1 }

        let a = alert("Add a Codex account",
                      "You will get a sign-in link to send to whoever owns the account. They sign"
                      + " in with their own ChatGPT account, in any browser, on any device."
                      + " Account \(label) appears on the widget only once they have finished."
                      + "\n\nFolder that keeps this account's login separate (its CODEX_HOME):")
        let field = NSTextField(string: "~/.codex-alt\(suffix)")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Create sign-in link")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let home = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !home.isEmpty else { return }
        if existing.contains(where: {
            $0.label == label || canonicalPath($0.home) == canonicalPath(home)
        }) {
            _ = alert("Already listed", "\(home) or label \(label) is already in the account list.",
                      style: .warning).runModal()
            return
        }
        do {
            try makePrivateDirectory(home)
        } catch {
            _ = alert("Could not create \(home)", error.localizedDescription,
                      style: .critical).runModal()
            return
        }
        startDeviceLogin(label: label, home: home, adding: true)
    }

    @objc func sendLoginLink(_ sender: NSMenuItem) {
        let accounts = loadAccounts()
        guard sender.tag < accounts.count else { return }
        startDeviceLogin(label: accounts[sender.tag].label, home: accounts[sender.tag].home,
                         adding: false)
    }

    /// One window per CODEX_HOME. When `adding`, the account is appended to the list only
    /// on a finished sign-in; a re-login leaves the list alone either way.
    func startDeviceLogin(label: String, home: String, adding: Bool) {
        let key = canonicalPath(home)
        if let open = deviceLogins[key] {
            open.present()
            return
        }
        guard let toolPath = resolveTool("codex") else {
            _ = alert("Codex is not installed", "Install it first with: npm install -g @openai/codex",
                      style: .warning).runModal()
            return
        }
        let login = DeviceLogin(toolPath: toolPath, home: home, callbackQueue: .main)
        let ui = DeviceLoginWindow(label: label, home: home, adding: adding, login: login)
        login.onLink = { [weak ui] link in ui?.show(link) }
        login.onExit = { [weak self, weak ui] outcome in
            guard let self else { return }
            var ok = outcome == .signedIn
            var text = outcome.message(label: label, home: home, adding: adding)
            if ok && adding {
                switch appendAccount(Account(label: label, home: home)) {
                case .saved: break
                case .duplicate:
                    ok = false
                    text = "Signed in, but \(label) or \(home) was added to the list meanwhile,"
                        + " so the list was left alone."
                case .failed:
                    ok = false
                    text = "Signed in, but writing \(accountsPath) failed, so \(label) was not added."
                }
            }
            if ok { self.accountsChanged() }
            ui?.finish(ok: ok, text: text, canRetry: outcome.canRetry)
        }
        ui.onRetry = { [weak self] in self?.startDeviceLogin(label: label, home: home, adding: adding) }
        ui.onClosed = { [weak self] in self?.deviceLogins.removeValue(forKey: key) }
        deviceLogins[key] = ui
        ui.present()
        if !login.start() {
            ui.finish(ok: false, text: "Codex could not be started from \(toolPath).", canRetry: true)
        }
    }

    @objc func loginAccount(_ sender: NSMenuItem) {
        let accounts = loadAccounts()
        guard sender.tag < accounts.count else { return }
        openLogin(home: accounts[sender.tag].home, label: accounts[sender.tag].label)
    }

    /// Hand authentication to Terminal. The CLI owns the browser/OAuth round trip; the
    /// widget receives only an exit status through a private sentinel and no credential.
    func openLogin(home: String, label: String) {
        launchAuth(toolName: "codex", environmentName: "CODEX_HOME", configDir: home,
                   product: "Codex", label: label, action: "Signing in",
                   arguments: ["login"],
                   install: "npm install -g @openai/codex")
    }

    func launchAuth(toolName: String, environmentName: String, configDir: String,
                    product: String, label: String, action: String,
                    arguments: [String], install: String,
                    onExit: ((Int32) -> Void)? = nil) {
        guard let toolPath = resolveTool(toolName) else {
            _ = alert("\(product) is not installed", "Install it first with: \(install)",
                      style: .warning).runModal()
            return
        }
        guard let launcher = makeAuthLauncher(toolPath: toolPath,
                                              environmentName: environmentName,
                                              configDir: configDir, product: product,
                                              label: label, action: action,
                                              arguments: arguments) else {
            _ = alert("Could not open Terminal", "Writing the private launcher failed.",
                      style: .critical).runModal()
            return
        }
        guard watchCompletion(at: launcher.sentinelPath, onExit: onExit) else {
            try? FileManager.default.removeItem(atPath: launcher.scriptPath)
            try? FileManager.default.removeItem(atPath: launcher.sentinelPath)
            _ = alert("Could not watch authentication",
                      "Opening the completion sentinel failed.", style: .critical).runModal()
            return
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: launcher.scriptPath)) else {
            completionSources.removeValue(forKey: launcher.sentinelPath)?.cancel()
            try? FileManager.default.removeItem(atPath: launcher.scriptPath)
            _ = alert("Could not open Terminal", "Open the account menu and try again.",
                      style: .critical).runModal()
            return
        }
    }

    func watchCompletion(at path: String, onExit: ((Int32) -> Void)? = nil) -> Bool {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self,
                  let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return }
            // A status is sufficient on both success and failure: either can change the
            // CLI's auth state, and the next fetch is the authoritative visible result.
            self.rebuildAccountsMenus()
            self.fetch(sync: false)
            self.completionSources.removeValue(forKey: path)?.cancel()
            let status = Int32(String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            onExit?(status)
        }
        source.setCancelHandler {
            _ = Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
        }
        completionSources[path] = source
        source.resume()
        return true
    }

    @objc func revealAccount(_ sender: NSMenuItem) {
        let accounts = loadAccounts()
        guard sender.tag < accounts.count else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expand(accounts[sender.tag].home))
    }

    @objc func removeAccount(_ sender: NSMenuItem) {
        let accounts = loadAccounts()
        guard sender.tag < accounts.count else { return }
        let gone = accounts[sender.tag]
        let a = alert("Remove account \(gone.label)?",
                      "It stops being read and stops being offered for dispatch.\n\n"
                      + "\(gone.home) is left on disk, login and all — add it back any time"
                      + " and it works again. Delete the folder yourself if you want the"
                      + " login really gone.", style: .warning)
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard updateAccounts({ current in current.filter { $0.label != gone.label } }) else {
            _ = alert("Could not save", "Writing \(accountsPath) failed.", style: .critical).runModal()
            return
        }
        accountsChanged()
    }

    @objc func addClaudeAccount() {
        let existing = loadClaudeAccounts()
        var number = 2
        while existing.contains(where: { $0.label == "Claude \(number)" }) { number += 1 }
        var suffix = ""
        var proposedDir = "~/.claude-alt"
        while existing.contains(where: {
            canonicalPath($0.configDir) == canonicalPath(proposedDir)
        }) {
            suffix = String((Int(suffix) ?? 1) + 1)
            proposedDir = "~/.claude-alt\(suffix)"
        }

        let a = alert("Add a Claude account",
                      "Each account needs its own CLAUDE_CONFIG_DIR. Sign-in runs in Terminal and"
                      + " can be finished in someone else's browser. The account is added only"
                      + " once it succeeds; this widget never sees credentials.")
        let labelField = NSTextField(string: "Claude \(number)")
        let dirField = NSTextField(string: proposedDir)
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        // Two standard 24pt text fields plus an 8pt gap measured from the existing dialog.
        for (title, field, y) in [("Label", labelField, CGFloat(32)),
                                  ("Folder", dirField, CGFloat(0))] {
            let caption = NSTextField(labelWithString: title)
            caption.frame = NSRect(x: 0, y: y + 3, width: 70, height: 18)
            field.frame = NSRect(x: 78, y: y, width: 242, height: 24)
            fields.addSubview(caption)
            fields.addSubview(field)
        }
        a.accessoryView = fields
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = labelField
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let configDir = dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !configDir.isEmpty else { return }
        let account = ClaudeAccount(label: label, configDir: configDir)
        if existing.contains(where: {
            $0.label == label || canonicalPath($0.configDir) == canonicalPath(configDir)
        }) {
            _ = alert("Already listed", "That label or folder is already a Claude account.",
                      style: .warning).runModal()
            return
        }
        try? makePrivateDirectory(configDir)
        guard confirmClaudeSignIn(account, adding: true) else { return }
        // Nothing is listed yet: only a finished `claude auth login` (status 0) adds it.
        launchClaudeLogin(account, action: "Signing in") { [weak self] code in
            guard let self else { return }
            guard code == 0 else {
                _ = self.alert("\(label) was not added",
                               "Claude's sign-in did not finish (it exited \(code)). Nothing was"
                               + " added; use Add Claude account… to try again.",
                               style: .warning).runModal()
                return
            }
            switch appendClaudeAccount(account) {
            case .saved: self.accountsChanged()
            case .duplicate:
                _ = self.alert("Already listed", "\(label) or \(configDir) was added meanwhile.",
                               style: .warning).runModal()
            case .failed:
                _ = self.alert("Could not save", "Writing \(claudeAccountsPath) failed.",
                               style: .critical).runModal()
            }
        }
    }

    @objc func loginClaudeAccount(_ sender: NSMenuItem) {
        let accounts = loadClaudeAccounts()
        guard sender.tag < accounts.count else { return }
        openClaudeLogin(accounts[sender.tag])
    }

    func openClaudeLogin(_ account: ClaudeAccount) {
        // The default account is the user's own and needs no hand-off steps.
        guard isDefaultClaudeAccount(account) || confirmClaudeSignIn(account, adding: false)
        else { return }
        launchClaudeLogin(account, action: "Re-authenticating", onExit: nil)
    }

    func launchClaudeLogin(_ account: ClaudeAccount, action: String,
                           onExit: ((Int32) -> Void)?) {
        launchAuth(toolName: "claude", environmentName: "CLAUDE_CONFIG_DIR",
                   configDir: account.configDir, product: "Claude", label: account.label,
                   action: action, arguments: ["auth", "login"],
                   install: "npm install -g @anthropic-ai/claude-code", onExit: onExit)
    }

    /// Claude Code has no device-code login. Its Terminal login shows a link that works in
    /// any browser, but the page it ends on shows a code that must be pasted back into
    /// Terminal, so the owner has one thing to send back. Strings from Claude Code 2.1.270.
    func confirmClaudeSignIn(_ account: ClaudeAccount, adding: Bool) -> Bool {
        let a = alert(adding ? "Sign in to add \(account.label)" : "Sign in \(account.label) again",
                      """
                      Terminal opens, and Claude also opens a sign-in tab in your browser here.

                      Signing in someone else's account:
                      1. Close the tab that opened on this Mac without approving. It would sign in as you.
                      2. In Terminal, copy the link under “Browser didn't open? Use the url below to sign in” and send it to them.
                      3. They open it, sign in with their own Claude account, and approve.
                      4. The page then shows a code. They must send that code back to you.
                      5. Paste it into Terminal at “Paste code here if prompted”.

                      Signing in your own account: just approve in the tab that opens.
                      """ + (adding ? "\n\n\(account.label) is added only once Terminal reports"
                                      + " the sign-in finished." : ""))
        a.addButton(withTitle: "Open Terminal")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func signOutClaudeAccount(_ sender: NSMenuItem) {
        let accounts = loadClaudeAccounts()
        guard sender.tag < accounts.count else { return }
        let account = accounts[sender.tag]
        let a = alert("Sign out of Claude account \(account.label)?",
                      "This runs claude auth logout in Terminal with CLAUDE_CONFIG_DIR="
                      + "\(account.configDir). The widget handles no credentials.",
                      style: .warning)
        a.addButton(withTitle: "Sign out")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        launchAuth(toolName: "claude", environmentName: "CLAUDE_CONFIG_DIR",
                   configDir: account.configDir, product: "Claude", label: account.label,
                   action: "Signing out", arguments: ["auth", "logout"],
                   install: "npm install -g @anthropic-ai/claude-code")
    }

    @objc func revealClaudeAccount(_ sender: NSMenuItem) {
        let accounts = loadClaudeAccounts()
        guard sender.tag < accounts.count else { return }
        NSWorkspace.shared.selectFile(nil,
            inFileViewerRootedAtPath: expand(accounts[sender.tag].configDir))
    }

    @objc func removeClaudeAccount(_ sender: NSMenuItem) {
        let accounts = loadClaudeAccounts()
        guard sender.tag < accounts.count else { return }
        let gone = accounts[sender.tag]
        guard !isDefaultClaudeAccount(gone) else {
            _ = alert("The default account cannot be removed",
                      "~/.claude is Claude Code's default configuration folder.",
                      style: .warning).runModal()
            return
        }
        let a = alert("Remove Claude account \(gone.label)?",
                      "\(gone.configDir) is left on disk, login and all. Add it back any"
                      + " time to restore it, or delete the folder yourself to remove it.",
                      style: .warning)
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var refusedDefault = false
        let saved = updateClaudeAccounts { current in
            guard let target = current.first(where: { $0.label == gone.label }) else {
                return current
            }
            guard !isDefaultClaudeAccount(target) else {
                refusedDefault = true
                return nil
            }
            let remaining = current.filter { $0.label != gone.label }
            return remaining.isEmpty ? [defaultClaudeAccount] : remaining
        }
        if refusedDefault {
            _ = alert("The default account cannot be removed",
                      "Its canonical folder is \(canonicalPath(defaultClaudeAccount.configDir)).",
                      style: .warning).runModal()
            return
        }
        guard saved else {
            _ = alert("Could not save", "Writing \(claudeAccountsPath) failed.",
                      style: .critical).runModal()
            return
        }
        accountsChanged()
    }

    @objc func refreshNow() { fetch(sync: false) }

    @objc func toggleDesktop(_ item: NSMenuItem) {
        onDesktop.toggle()
        item.state = onDesktop ? .on : .off
    }

    // MARK: - data

    func fetch(sync: Bool) {
        guard !busy else { return }  // a slow API read must not stack up behind the timer
        busy = true
        let work = { [weak self] in
            guard let self else { return }
            // Order matters — see the file header.
            let codex = runJSON(appHome + "/statusline.py")
            let mode = runJSON(appHome + "/work-mode.py")
            let apply = {
                self.build(codex: codex, mode: mode)
                self.busy = false
            }
            if sync { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        if sync { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    func build(codex: [String: Any]?, mode: [String: Any]?) {
        var m = Model()
        m.warn = cleanPct(codex?["warn_at"]) ?? 60
        m.alert = cleanPct(codex?["alert_at"]) ?? 85
        var chips: [(String, NSColor)] = []

        for case let a as [String: Any] in (codex?["accounts"] as? [Any] ?? []) {
            let label = a["label"] as? String ?? "?"
            let path = a["home"] as? String ?? ""
            let stale = a["stale"] as? Bool ?? false
            let slots = a["slots"] as? [String: Any] ?? [:]
            if slots.isEmpty {
                let why = a["reason"] as? String ?? "no figure"
                m.codex.append(Bar(name: label, detail: path,
                                   pct: nil, note: why == "expired" ? "login expired" : why,
                                   stale: false))
                chips.append((label + "—", red))
                continue
            }
            // 7d first — it is the window that decides dispatch — then anything else.
            let order = (slots.keys.contains("7d") ? ["7d"] : []) + slots.keys.filter { $0 != "7d" }.sorted()
            for (i, key) in order.enumerated() {
                guard let slot = slots[key] as? [String: Any], let pct = cleanPct(slot["pct"]) else { continue }
                // Show a secondary window only when it has actually been used — an empty
                // 5h row beside a spent 7d row tells you nothing about what is blocking.
                if i > 0 && pct <= 0 { continue }
                m.codex.append(Bar(name: i == 0 ? "\(label)  \(key)" : "    \(key)",
                                   detail: i == 0 ? path : "",
                                   pct: pct, note: resetText(slot["resets_at"] as? Double),
                                   stale: stale))
                if i == 0 {
                    chips.append((label + String(Int(pct.rounded())) + (stale ? "*" : ""),
                                  colour(pct, warn: m.warn, alert: m.alert)))
                }
            }
        }
        if codex == nil {
            m.codex.append(Bar(name: "Codex", detail: "could not read usage", pct: nil, note: "", stale: false))
            chips.append(("codex?", red))
        }

        if let c = mode?["claude"] as? [String: Any] {
            // work-mode serves a cached figure while the endpoint is cooling down; mark it
            // like a cached Codex figure so neither the card nor the chip passes it as live.
            let stale = c["stale"] as? Bool ?? false
            for key in ["7d", "5h"] {
                guard let pct = cleanPct(c[key]) else { continue }
                m.claude.append(Bar(name: key, detail: "", pct: pct, note: "", stale: stale))
            }
            // Claude rides the same chip as Codex, with its 7-day figure like each Codex
            // account's. "CL" because a lone "C" is already a Codex label, and "Cl" reads
            // as "CI" in this font.
            if let pct = cleanPct(c["7d"]) {
                chips.append(("CL" + String(Int(pct.rounded())) + (stale ? "*" : ""),
                              colour(pct, warn: m.warn, alert: m.alert)))
            } else {
                chips.append(("CL?", red))
            }
        } else {
            m.claude.append(Bar(name: "Claude", detail: "budget unreadable", pct: nil, note: "", stale: false))
            chips.append(("CL?", red))
        }
        m.mode = mode?["mode"] as? String ?? "UNKNOWN"
        m.why = mode?["why"] as? String ?? ""

        model = m
        panels.values.forEach { $0.apply(m) }

        let chip = NSMutableAttributedString()
        for (i, c) in chips.enumerated() {
            if i > 0 { chip.append(NSAttributedString(string: " ")) }
            chip.append(NSAttributedString(string: c.0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: c.1,
            ]))
        }
        chipText = chip.string
        chipSegments = chips
        statusItem?.button?.attributedTitle = chip
    }

    // MARK: - headless checks

    /// Preserve hierarchy and action identity so tests can distinguish two identically
    /// titled Remove items and prove the canonical default-account one is disabled.
    func checkMenus() {
        guard let menu = statusMenu else { return }
        func walk(_ current: NSMenu, depth: Int) {
            for item in current.items {
                let action = item.action.map(NSStringFromSelector) ?? ""
                print("\(depth)\t\(item.title)\t\(item.isEnabled)\t\(action)\t\(item.tag)")
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
        }
        walk(menu, depth: 0)
    }

    /// Print what the card holds. Cheap, and it catches parse/order regressions.
    func dumpText() {
        let m = model
        for b in m.codex + m.claude {
            print(String(format: "%-12s %5s  %-16s %s",
                         (b.name as NSString).utf8String!,
                         ((b.pct.map { String(Int($0.rounded())) + "%" } ?? "—") as NSString).utf8String!,
                         (b.detail as NSString).utf8String!,
                         (b.note as NSString).utf8String!))
        }
        print("mode: \(m.mode) — \(m.why)")
        print("menu bar: \(chipText)")
        print("accounts: " + loadAccounts().map { "\($0.label)=\($0.home)" }.joined(separator: " "))
        for cardPanel in panels.values.sorted(by: { $0.displayID < $1.displayID }) {
            print("card on display \(cardPanel.displayID): \(cardPanel.panel.frame) "
                  + "level=\(cardPanel.panel.level.rawValue) screen=\(cardPanel.screen?.frame.size ?? .zero)")
        }
    }

    /// The app icon: the widget's own three bars, so Spotlight shows what it opens.
    func writeIcon(_ path: String) {
        let size: CGFloat = 1024
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
                            NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1)])?
            .draw(in: rect, angle: -90)
        let height = size * 0.085, gap = size * 0.085
        let left = size * 0.17, full = size * 0.66
        var y = size * 0.6275  // three bars + two gaps = 0.425 tall, vertically centred
        for (fraction, tint) in [(0.42, green), (0.74, amber), (1.0, red)] {
            let bar = NSRect(x: left, y: y, width: full, height: height)
            NSColor(white: 1, alpha: 0.15).setFill()
            NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: full * fraction, height: height),
                         xRadius: height / 2, yRadius: height / 2).fill()
            y -= height + gap
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// Write the card to a PNG by asking its own view to draw. Needs no Screen Recording
    /// permission — the app owns the view — so the layout can be checked on any run.
    func shot(_ path: String) {
        guard let card = panels.values.first?.card,
              let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// The Codex link window with a sample link, drawn by its own view like --shot.
    func loginShot(_ path: String) {
        let unstarted = DeviceLogin(toolPath: "/usr/bin/false", home: "~/.codex-example",
                                    callbackQueue: .main)
        let ui = DeviceLoginWindow(label: "D", home: "~/.codex-example", adding: true,
                                   login: unstarted)
        ui.show(DeviceLink(url: "https://auth.openai.com/codex/device", code: "ABCD-12345",
                           minutes: 15))
        guard let png = ui.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

// Before AppKit starts: these need no window server and must work over ssh.
if accountsCLI(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon, no app switcher entry
// A second copy launched from Spotlight hands off to the running one and gets out of the way.
if !headless,
   NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    DistributedNotificationCenter.default().postNotificationName(showPanelNote, object: nil,
                                                                userInfo: nil, deliverImmediately: true)
    exit(0)
}
let widget = Widget()
app.delegate = widget
if headless {
    // A command-line binary has no app bundle for Launch Services to notify. Drive the
    // same delegate entry point synchronously so verification never waits on a run loop.
    widget.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification, object: app))
} else {
    app.run()
}
