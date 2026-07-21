// Claude 双账户重置 —— 无后端单体版 v2
// 一个菜单栏 App 干完所有事：读钥匙串 → 拉 Anthropic 用量 → 菜单栏展示。
// 只关注两件事：周限额(用量+重置时间) 和 Fable 周容量(用量+重置时间)。
// robust 设计：
//   - 上游只由一个 120s 定时循环访问，打开菜单/手动刷新都有节流，不会放大请求
//   - 429 读 Retry-After + 指数退避(2→4→8→…最多30分钟)
//   - 拉取失败时继续显示上次成功的数据(橙色降级标记)，而不是报错清空
//   - 快照落盘到二进制同目录 state.json，重启后立刻有数据
// 安装: 仓库根目录跑 ./install.sh（编译 + 装到 ~/Library/Application Support/claude-reset + 注册 LaunchAgent）
import Cocoa

// ---- 配置 ----
struct AcctCfg { let id: String; let label: String; let email: String; let keychain: String }
let ACCOUNTS = [
    AcctCfg(id: "a", label: "A", email: "account-a@example.com", keychain: "Claude Code-credentials"),
    AcctCfg(id: "b", label: "B", email: "account-b@example.com", keychain: "Claude Code-credentials-CHANGEME"),
]
let USAGE_URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let BETA_HEADER = "oauth-2025-04-20"
let POLL_SEC: TimeInterval = 120        // 上游拉取节奏（唯一会打上游的地方）
let MENU_STALE_SEC: TimeInterval = 60   // 打开菜单时数据比这旧才顺带触发一次刷新
let FORCE_MIN_GAP: TimeInterval = 15    // 手动“立即刷新”最小间隔
let HOME = FileManager.default.homeDirectoryForCurrentUser
let CURRENT_ACCT_FILE = HOME.appendingPathComponent(".claude-current-acct")
// 状态文件放二进制同目录（安装后即 Application Support），源码仓库保持干净
let EXE_DIR = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let STATE_FILE = EXE_DIR.appendingPathComponent("state.json")

func j(_ v: Any?) -> Any { v ?? NSNull() }

let isoPlain = ISO8601DateFormatter()
let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func isoEpoch(_ s: String?) -> Double? {
    guard let s = s else { return nil }
    return (isoPlain.date(from: s) ?? isoFrac.date(from: s))?.timeIntervalSince1970
}

// ---- 数据模型 ----
struct Block {
    var pct: Double?
    var resetsEpoch: Double?
    var dict: [String: Any] { ["pct": j(pct), "resets_epoch": j(resetsEpoch)] }
    static func from(_ v: Any?) -> Block? {          // state.json 格式
        guard let d = v as? [String: Any] else { return nil }
        return Block(pct: d["pct"] as? Double, resetsEpoch: d["resets_epoch"] as? Double)
    }
    static func upstream(_ v: Any?) -> Block? {      // API 格式
        guard let d = v as? [String: Any] else { return nil }
        return Block(pct: d["utilization"] as? Double, resetsEpoch: isoEpoch(d["resets_at"] as? String))
    }
}

struct AcctSnap {
    var cfg: AcctCfg
    var active = false
    var error: String?       // 最近一次拉取的错误(nil=成功)；出错不清空旧数据
    var weekly: Block?       // 周限额(全模型)
    var fable: Block?        // Fable 周容量
    var dataAt: Date?        // 数据成功拉到的时间
}

final class Ref<T> { var v: T; init(_ v: T) { self.v = v } }

// ---- 取数与缓存 ----
final class UsageStore {
    static let shared = UsageStore()
    private let stateQ = DispatchQueue(label: "state")   // 只做快速读写
    private let workQ = DispatchQueue(label: "work")     // 子进程 + 网络
    private var snaps: [AcctSnap]
    private var refreshing = false
    private var lastAttempt = Date.distantPast
    private var notBefore = Date.distantPast             // 429 退避闸门
    private var backoff: TimeInterval = 0
    var onUpdate: (() -> Void)?                          // 主线程回调

    private init() {
        snaps = ACCOUNTS.map { AcctSnap(cfg: $0) }
        if let d = try? Data(contentsOf: STATE_FILE),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
            for i in snaps.indices {
                guard let e = obj[snaps[i].cfg.id] else { continue }
                snaps[i].weekly = Block.from(e["weekly"])
                snaps[i].fable = Block.from(e["fable"])
                snaps[i].dataAt = (e["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            }
        }
    }

    func snapshot() -> [AcctSnap] {
        let cur = ((try? String(contentsOf: CURRENT_ACCT_FILE, encoding: .utf8)) ?? "a")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [AcctSnap] = []
        stateQ.sync { out = snaps }
        for i in out.indices { out[i].active = out[i].cfg.id == cur }
        return out
    }

    func backoffRemaining() -> TimeInterval? {
        var t: TimeInterval?
        stateQ.sync { if notBefore > Date() { t = notBefore.timeIntervalSinceNow } }
        return t
    }

    func dataAge() -> TimeInterval? {
        var newest: Date?
        stateQ.sync { newest = snaps.compactMap { $0.dataAt }.max() }
        return newest.map { -$0.timeIntervalSinceNow }
    }

    func refresh(force: Bool = false) {
        let now = Date()
        var go = false
        stateQ.sync {
            if refreshing { return }
            if now.timeIntervalSince(lastAttempt) < FORCE_MIN_GAP { return }
            if !force && now < notBefore { return }
            refreshing = true; lastAttempt = now; go = true
        }
        guard go else { return }
        workQ.async { self.doRefresh() }
    }

    private func doRefresh() {
        let group = DispatchGroup()
        let resQ = DispatchQueue(label: "res")
        var results = [String: (Block?, Block?, String?, Double?)]()  // id -> (weekly, fable, err, retryAfter)
        for cfg in ACCOUNTS {
            group.enter()
            DispatchQueue.global().async {
                let r = Self.fetchAccount(cfg)
                resQ.sync { results[cfg.id] = r }
                group.leave()
            }
        }
        group.wait()
        let now = Date()
        var rateLimited: Double?
        stateQ.sync {
            for i in snaps.indices {
                guard let r = results[snaps[i].cfg.id] else { continue }
                if let err = r.2 {
                    snaps[i].error = err
                    if err == "http_429" { rateLimited = max(rateLimited ?? 0, r.3 ?? 0) }
                } else {
                    snaps[i].error = nil
                    snaps[i].weekly = r.0
                    snaps[i].fable = r.1
                    snaps[i].dataAt = now
                }
            }
            if let ra = rateLimited {
                backoff = backoff == 0 ? 120 : min(backoff * 2, 1800)
                if ra > backoff { backoff = min(ra, 3600) }
                notBefore = now.addingTimeInterval(backoff)
            } else {
                backoff = 0
                notBefore = .distantPast
            }
            refreshing = false
        }
        saveState()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    private func saveState() {
        var obj = [String: Any]()
        stateQ.sync {
            for s in snaps where s.dataAt != nil {
                obj[s.cfg.id] = ["at": s.dataAt!.timeIntervalSince1970,
                                 "weekly": j(s.weekly?.dict), "fable": j(s.fable?.dict)]
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: STATE_FILE, options: .atomic)
        }
    }

    // 解析：以 limits 数组为准（weekly_all=周限额，weekly_scoped=Fable 桶），缺失时退回 seven_day
    static func parseUsage(_ obj: [String: Any]) -> (Block?, Block?) {
        var weekly = Block.upstream(obj["seven_day"])
        var fable: Block?
        if let limits = obj["limits"] as? [[String: Any]] {
            func blk(_ d: [String: Any]) -> Block {
                Block(pct: (d["percent"] as? NSNumber)?.doubleValue,
                      resetsEpoch: isoEpoch(d["resets_at"] as? String))
            }
            var scoped: [[String: Any]] = []
            for l in limits {
                switch l["kind"] as? String {
                case "weekly_all": weekly = blk(l)
                case "weekly_scoped": scoped.append(l)
                default: break
                }
            }
            func modelName(_ l: [String: Any]) -> String {
                (((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String) ?? ""
            }
            let pick = scoped.first { modelName($0).localizedCaseInsensitiveContains("fable") } ?? scoped.first
            fable = pick.map(blk)
        }
        return (weekly, fable)
    }

    static func fetchAccount(_ cfg: AcctCfg) -> (Block?, Block?, String?, Double?) {
        guard let token = readToken(cfg.keychain) else { return (nil, nil, "no_token", nil) }
        var req = URLRequest(url: USAGE_URL)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BETA_HEADER, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-reset-widget/2.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        let out = Ref<(Block?, Block?, String?, Double?)>((nil, nil, "err_timeout", nil))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil { out.v = (nil, nil, "err_network", nil); return }
            guard let http = resp as? HTTPURLResponse else { out.v = (nil, nil, "err_network", nil); return }
            if http.statusCode == 401 { out.v = (nil, nil, "token_expired", nil); return }
            if http.statusCode == 429 {
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                out.v = (nil, nil, "http_429", ra); return
            }
            guard http.statusCode == 200, let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                out.v = (nil, nil, "http_\(http.statusCode)", nil); return
            }
            let (w, f) = parseUsage(obj)
            out.v = (w, f, nil, nil)
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return out.v
    }

    static func readToken(_ service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return nil }
        if sem.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let oauth = obj["claudeAiOauth"] as? [String: Any] ?? obj
        return oauth["accessToken"] as? String
    }
}

// ---- 展示工具 ----
func sevColor(_ p: Double) -> NSColor {
    if p >= 90 { return .systemRed }
    if p >= 70 { return .systemOrange }
    return .labelColor
}

func countdown(_ epoch: Double?) -> String {
    guard let e = epoch else { return "—" }
    var s = Int(e - Date().timeIntervalSince1970)
    if s <= 0 { return "已重置" }
    let d = s / 86400; s %= 86400
    let h = s / 3600;  s %= 3600
    let m = s / 60
    if d > 0 { return "还剩 \(d)天\(h)时" }
    if h > 0 { return "还剩 \(h)时\(m)分" }
    return "还剩 \(m)分"
}

func resetAt(_ epoch: Double?) -> String {
    guard let e = epoch else { return "" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: e))
}

func ageText(_ t: TimeInterval) -> String {
    if t < 90 { return "刚刚" }
    if t < 5400 { return "\(Int(t / 60)) 分钟前" }
    return String(format: "%.1f 小时前", t / 3600)
}

func errText(_ code: String) -> String {
    switch code {
    case "token_expired": return "Token 过期 · 跑一次 claude 刷新"
    case "no_token":      return "钥匙串无凭据"
    case "http_429":      return "上游限流(429)"
    default:              return "拉取失败: \(code)"
    }
}

// ---- App ----
class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let store = UsageStore.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⟳"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        store.onUpdate = { [weak self] in self?.render() }
        store.refresh()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: POLL_SEC, repeats: true) { [weak self] _ in
            self?.store.refresh()
            self?.render()   // 即便被退避拦下也刷新一下界面上的时间显示
        }
        timer?.tolerance = 10
    }

    func menuWillOpen(_ menu: NSMenu) {
        if (store.dataAge() ?? .infinity) > MENU_STALE_SEC { store.refresh() }
        render()
    }

    // 菜单栏标题: 每账户一个彩点 + 更紧的那个桶的用量%（Fable 桶带 F 前缀）
    func render() {
        let snaps = store.snapshot()
        let dot: [NSColor] = [.systemGreen, .systemBlue]
        let title = NSMutableAttributedString()
        for (i, s) in snaps.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ")) }
            title.append(NSAttributedString(string: "● ", attributes: [
                .foregroundColor: dot[i % dot.count],
                .font: NSFont.systemFont(ofSize: 9)]))
            let w = s.weekly?.pct, f = s.fable?.pct
            let txt: String; var col: NSColor
            if w == nil && f == nil {
                txt = s.error != nil ? "!" : "—"
                col = s.error != nil ? .systemRed : .secondaryLabelColor
            } else if (f ?? -1) >= (w ?? -1) {
                txt = "F\(Int(f!))%"; col = sevColor(f!)
            } else {
                txt = "\(Int(w!))%"; col = sevColor(w!)
            }
            if s.error != nil && (w != nil || f != nil) { col = .systemOrange }  // 降级：显示旧数据
            title.append(NSAttributedString(string: txt, attributes: [
                .foregroundColor: col,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        }
        statusItem.button?.attributedTitle = title
        rebuildMenu(snaps)
    }

    func infoItem(_ s: NSAttributedString) -> NSMenuItem {
        let mi = NSMenuItem(); mi.attributedTitle = s; mi.isEnabled = true; return mi
    }

    func rebuildMenu(_ snaps: [AcctSnap]) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor,
                                                  .font: NSFont.systemFont(ofSize: 12)]
        let dotCol: [NSColor] = [.systemGreen, .systemBlue]

        for (i, s) in snaps.enumerated() {
            let head = NSMutableAttributedString()
            head.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dotCol[i % dotCol.count]]))
            head.append(NSAttributedString(string: "账户 \(s.cfg.label)  ", attributes:
                [.font: NSFont.boldSystemFont(ofSize: 13)]))
            head.append(NSAttributedString(string: s.cfg.email, attributes: dim))
            if s.active {
                head.append(NSAttributedString(string: "  ● 在用", attributes:
                    [.foregroundColor: NSColor.systemGreen, .font: NSFont.systemFont(ofSize: 11)]))
            }
            menu.addItem(infoItem(head))

            if s.weekly == nil && s.fable == nil {
                let msg = s.error.map(errText) ?? "暂无数据"
                menu.addItem(infoItem(NSAttributedString(string: "   " + msg,
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 12)])))
            } else {
                menu.addItem(infoItem(row("周限额", s.weekly)))
                menu.addItem(infoItem(row("Fable ", s.fable)))
                if let e = s.error, let at = s.dataAt {
                    menu.addItem(infoItem(NSAttributedString(
                        string: "   ⚠ \(errText(e)) · 显示 \(ageText(-at.timeIntervalSinceNow))的数据",
                        attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 11)])))
                }
            }
            if i < snaps.count - 1 { menu.addItem(.separator()) }
        }

        menu.addItem(.separator())
        if let left = store.backoffRemaining() {
            menu.addItem(infoItem(NSAttributedString(
                string: "上游限流中 · \(Int(left / 60) + 1) 分钟后自动重试",
                attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 11)])))
        }
        if let age = store.dataAge() {
            menu.addItem(infoItem(NSAttributedString(
                string: "数据更新于 \(ageText(age)) · 每 \(Int(POLL_SEC / 60)) 分钟拉取",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])))
        }
        add(menu, "立即刷新", #selector(doRefresh), "r")
        add(menu, "退出", #selector(quit), "q")
    }

    // "周限额   40%   还剩 2天3时 · 07-24 08:00"  /  "剩 X%" 直接回答“还剩多少”
    func row(_ name: String, _ b: Block?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "   \(name)   ", attributes:
            [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        guard let b = b, b.pct != nil || b.resetsEpoch != nil else {
            out.append(NSAttributedString(string: "无数据", attributes:
                [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            return out
        }
        let pct = b.pct ?? 0
        out.append(NSAttributedString(string: "剩 \(max(0, 100 - Int(pct)))%",
            attributes: [.foregroundColor: sevColor(pct),
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))
        out.append(NSAttributedString(string: "  " + countdown(b.resetsEpoch), attributes:
            [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]))
        out.append(NSAttributedString(string: "  · " + resetAt(b.resetsEpoch), attributes:
            [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        return out
    }

    func add(_ menu: NSMenu, _ t: String, _ sel: Selector, _ key: String) {
        let mi = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        mi.target = self; mi.isEnabled = true; menu.addItem(mi)
    }

    @objc func doRefresh() { store.refresh(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，只在菜单栏
app.run()
