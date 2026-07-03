import AppKit

// MARK: - Localization

let isRU = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false

func L(_ en: String, _ ru: String) -> String { isRU ? ru : en }

// MARK: - Usage response models (/api/oauth/usage)

struct LimitScope: Decodable {
    struct ModelInfo: Decodable { let display_name: String? }
    let model: ModelInfo?
}

struct LimitEntry: Decodable {
    let kind: String
    let percent: Double?
    let resets_at: String?
    let scope: LimitScope?
}

struct UsageResponse: Decodable {
    let limits: [LimitEntry]?
}

struct KeychainCreds: Decodable {
    struct OAuth: Decodable { let accessToken: String? }
    let claudeAiOauth: OAuth?
}

// MARK: - Keychain

enum TokenError: Error {
    case noKeychainItem   // Claude Code not installed / never logged in
    case noToken          // item exists but no OAuth token inside
    case timeout          // security CLI hung (e.g. locked keychain prompt)
}

/// Blocking read of Claude Code's OAuth token. Call off the main thread only.
///
/// Uses the `security` CLI rather than SecItemCopyMatching: Claude Code creates
/// the item through that CLI, so its ACL already covers /usr/bin/security and
/// the read is silent. A native API call from this ad-hoc-signed binary would
/// trigger a keychain permission dialog instead.
func readAccessTokenSync() -> Result<String, TokenError> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return .failure(.noKeychainItem) }

    // If the keychain is locked, `security` can hang on a GUI prompt — bail out
    // instead of wedging the poll pipeline.
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    if done.wait(timeout: .now() + 10) == .timedOut {
        p.terminate()
        return .failure(.timeout)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0 else { return .failure(.noKeychainItem) }
    guard let creds = try? JSONDecoder().decode(KeychainCreds.self, from: data),
          let token = creds.claudeAiOauth?.accessToken, !token.isEmpty
    else { return .failure(.noToken) }
    return .success(token)
}

// MARK: - Formatting (cached, locale-aware)

let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoParserNoFrac = ISO8601DateFormatter()

let shortTime: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short   // honors the user's 12/24-hour preference
    return f
}()
let weekday: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("E")
    return f
}()
let clockTime: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .medium
    return f
}()

func parseDate(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
}

func resetString(_ s: String?) -> String {
    guard let d = parseDate(s) else { return "" }
    let cal = Calendar.current
    let prefix = L("resets ", "до ")
    if cal.isDateInToday(d) {
        return prefix + shortTime.string(from: d)
    } else if cal.isDateInTomorrow(d) {
        return prefix + L("tomorrow ", "завтра ") + shortTime.string(from: d)
    } else {
        return prefix + weekday.string(from: d) + " " + shortTime.string(from: d)
    }
}

// MARK: - App

struct ScopedLimit {
    let name: String
    let pct: Int
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?

    // Data
    var sessionPct: Int = -1
    var weeklyAllPct: Int = -1
    var scoped: [ScopedLimit] = []
    var sessionReset = ""
    var weeklyReset = ""
    var lastError: String?
    var lastUpdate: Date?

    // Networking state
    var cachedToken: String?
    var generation = 0                            // drops out-of-order responses
    var nextAllowedUptime: TimeInterval = 0       // 15s burst throttle
    var backoffUntilUptime: TimeInterval = 0      // 429 backoff (monotonic clock)

    // Menu state
    var menuOpen = false
    var menuDirty = false
    var statItems: [NSMenuItem] = []
    var errorItem = NSMenuItem()
    var updatedItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: yield only to an OLDER instance, so a simultaneous
        // double-launch can never terminate both. Skipped for bare-binary runs
        // (nil bundle id) — those are dev builds.
        if let bid = Bundle.main.bundleIdentifier {
            let me = NSRunningApplication.current
            let older = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != me.processIdentifier }
                .contains { other in
                    let a = other.launchDate ?? .distantPast
                    let b = me.launchDate ?? Date()
                    return a < b || (a == b && other.processIdentifier < me.processIdentifier)
                }
            if older {
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✳︎ …"
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
        refresh()
        // Poll interval: `defaults write ru.khanin.kvota interval -int 30` (min 30, default 60)
        let stored = UserDefaults.standard.integer(forKey: "interval")
        let interval = TimeInterval(stored >= 30 ? stored : 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = interval / 6
    }

    func refresh(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        // Server backoff is never bypassed — a manual refresh during a 429
        // would only extend the rate limiting.
        if now < backoffUntilUptime { return }
        if now < nextAllowedUptime, !force { return }
        nextAllowedUptime = now + 15

        generation += 1
        let gen = generation

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let token: String
            if let cached = self.cachedToken {
                token = cached
            } else {
                switch readAccessTokenSync() {
                case .success(let t):
                    token = t
                    DispatchQueue.main.async { self.cachedToken = t }
                case .failure(let e):
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        switch e {
                        case .noKeychainItem:
                            self.lastError = L("Claude Code not found — install it and log in",
                                               "Claude Code не найден — установи и залогинься")
                        case .noToken:
                            self.lastError = L("No OAuth token — run `claude` and log in",
                                               "Нет OAuth-токена — запусти `claude` и залогинься")
                        case .timeout:
                            self.lastError = L("Keychain not responding (locked?)",
                                               "Keychain не отвечает (заблокирован?)")
                        }
                        self.updateUI()
                    }
                    return
                }
            }

            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15

            URLSession.shared.dataTask(with: req) { data, resp, err in
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }   // stale response
                    defer { self.updateUI() }
                    if let err = err {
                        self.lastError = L("Network: ", "Сеть: ") + err.localizedDescription
                        return
                    }
                    guard let http = resp as? HTTPURLResponse else {
                        self.lastError = L("No HTTP response", "Нет HTTP-ответа")
                        return
                    }
                    if http.statusCode == 429 {
                        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")
                                            .flatMap(Double.init)) ?? 300
                        self.backoffUntilUptime = ProcessInfo.processInfo.systemUptime
                                                  + min(max(retryAfter, 60), 3600)
                        self.lastError = L("Rate limited — pausing for \(Int(retryAfter/60)) min",
                                           "Лимит запросов — пауза \(Int(retryAfter/60)) мин")
                        return
                    }
                    if http.statusCode == 401 {
                        self.cachedToken = nil   // re-read next cycle: Claude Code may have rotated it
                        self.lastError = L("Token expired — open Claude Code once to refresh it",
                                           "Токен протух — открой Claude Code, он обновит")
                        return
                    }
                    guard http.statusCode == 200, let data = data else {
                        self.lastError = "HTTP \(http.statusCode)"
                        return
                    }
                    guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data),
                          let limits = usage.limits else {
                        self.lastError = L("Could not parse response", "Не смог разобрать ответ")
                        return
                    }
                    self.apply(limits)
                }
            }.resume()
        }
    }

    /// Replace all displayed limit state from a fresh response. Kinds absent
    /// from the payload reset to "unknown" instead of keeping stale values.
    func apply(_ limits: [LimitEntry]) {
        lastError = nil
        lastUpdate = Date()
        sessionPct = -1
        weeklyAllPct = -1
        scoped = []
        sessionReset = ""
        weeklyReset = ""
        for l in limits {
            guard let percent = l.percent else { continue }   // null ≠ 0%
            let pct = Int(percent.rounded())
            switch l.kind {
            case "session":
                sessionPct = pct
                sessionReset = resetString(l.resets_at)
            case "weekly_all":
                weeklyAllPct = pct
                weeklyReset = resetString(l.resets_at)
            case "weekly_scoped":
                scoped.append(ScopedLimit(
                    name: l.scope?.model?.display_name ?? L("model", "модель"),
                    pct: pct))
            default: break
            }
        }
    }

    var maxPct: Int {
        max(sessionPct, weeklyAllPct, scoped.map(\.pct).max() ?? -1)
    }

    func updateUI() {
        guard let button = statusItem.button else { return }
        if sessionPct < 0 && lastUpdate == nil {
            button.title = lastError == nil ? "✳︎ …" : "✳︎ !"
        } else {
            let warn = maxPct >= 90 ? "⚠️" : ""
            let staleMark = lastError != nil ? "!" : ""
            let pctStr = sessionPct >= 0 ? "\(sessionPct)%" : "–"
            button.title = "\(warn)✳︎ \(pctStr)\(staleMark)"
        }
        // Updating item titles in place is safe while the menu is open;
        // only structural changes (row count) require a full rebuild.
        if statItems.count == 2 + scoped.count {
            fillMenu()
        } else if menuOpen {
            menuDirty = true
        } else {
            rebuildMenu()
        }
    }

    func bar(_ pct: Int) -> String {
        guard pct >= 0 else { return "" }
        let filled = min(10, max(0, pct / 10))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 10 - filled)
    }

    /// Rebuild the menu structure: one item per stat row plus fixed slots.
    func rebuildMenu() {
        menu.removeAllItems()
        statItems = (0..<(2 + scoped.count)).map { _ in
            let item = NSMenuItem()
            item.isEnabled = false
            menu.addItem(item)
            return item
        }

        menu.addItem(.separator())

        errorItem = NSMenuItem()
        errorItem.isEnabled = false
        menu.addItem(errorItem)
        updatedItem = NSMenuItem()
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        let refreshItem = NSMenuItem(title: L("Refresh", "Обновить"), action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let ghItem = NSMenuItem(title: "GitHub", action: #selector(openGitHub), keyEquivalent: "")
        ghItem.target = self
        menu.addItem(ghItem)

        let quitItem = NSMenuItem(title: L("Quit", "Выход"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        fillMenu()
    }

    /// Refresh item contents in place — safe even while the menu is open.
    func fillMenu() {
        func statTitle(_ title: String, _ pct: Int, _ extra: String) -> NSAttributedString {
            let pctStr = pct >= 0 ? "\(pct)%" : "–"
            // Two separately-attributed runs appended — no range arithmetic,
            // safe for any Unicode in `title` (model names come from the API).
            let attr = NSMutableAttributedString(
                string: "\(title): \(pctStr)  \(extra)",
                attributes: [.font: NSFont.menuFont(ofSize: 13)])
            attr.append(NSAttributedString(
                string: "\n" + bar(pct),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                             .foregroundColor: pct >= 90 ? NSColor.systemRed
                                             : (pct >= 70 ? NSColor.systemOrange : NSColor.systemGreen)]))
            return attr
        }

        guard statItems.count == 2 + scoped.count else { return }
        statItems[0].attributedTitle = statTitle(L("5-hour", "5 часов"), sessionPct, sessionReset)
        statItems[1].attributedTitle = statTitle(L("Weekly (all)", "Неделя (все)"), weeklyAllPct, weeklyReset)
        for (i, s) in scoped.enumerated() {
            statItems[2 + i].attributedTitle = statTitle(L("Weekly (\(s.name))", "Неделя (\(s.name))"), s.pct, "")
        }

        if let err = lastError {
            errorItem.title = "⚠️ \(err)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
        if let upd = lastUpdate {
            updatedItem.title = L("Updated ", "Обновлено ") + clockTime.string(from: upd)
            updatedItem.isHidden = false
        } else {
            updatedItem.isHidden = true
        }
    }

    @objc func manualRefresh() { refresh(force: true) }
    @objc func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/vaskhan/claude-kvota")!)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if menuDirty {
            menuDirty = false
            rebuildMenu()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
