// Claude 双账户重置 —— 无后端单体版 v2
// 一个菜单栏 App 干完所有事：读钥匙串 → 拉 Anthropic 用量 → 菜单栏展示。
// 只关注两件事：周限额(用量+重置时间) 和 Fable 周容量(用量+重置时间)。
// robust 设计：
//   - 背景轮询极懒：每 30 分钟只拉一个账户，两账户轮流（单账户 1 小时一次）；
//     打开菜单时数据超过 3 分钟旧才即时补拉一次，手动刷新也有节流
//     （usage 接口限流极紧：实测持续 1 请求/分钟仍会 429，务必保持低频）
//   - 429 按账户独立退避：max(Retry-After, 5→10→20…分钟, 上限1小时)，另有 60s 全局冷却；
//     一个账户被限流不冻结另一个账户的更新
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
let POLL_SEC: TimeInterval = 1800       // 定时节奏：每 tick 只拉一个账户，两账户轮流（单账户 1 小时一次）
                                        // 周额度是慢变量，背景轮询宁懒勿勤；打开菜单时数据过旧会即时补拉
let MENU_STALE_SEC: TimeInterval = 180  // 打开菜单时最旧账户数据比这旧才顺带触发一次拉取
let FORCE_MIN_GAP: TimeInterval = 30    // 手动“立即刷新”最小间隔
let TICK_MIN_GAP: TimeInterval = 15     // 自动拉取去重间隔（定时器与菜单打开撞车时）
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
    var notBefore = Date.distantPast   // 该账户的 429 退避闸门
    var backoff: TimeInterval = 0
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
    private var globalCooldown = Date.distantPast        // 任一账户 429 后的短全局冷却
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

    // 数据最新的账户的年龄（给页脚显示）
    func dataAge() -> TimeInterval? {
        var newest: Date?
        stateQ.sync { newest = snaps.compactMap { $0.dataAt }.max() }
        return newest.map { -$0.timeIntervalSinceNow }
    }

    // 数据最旧的账户的年龄（给菜单打开时判断要不要顺带拉一次）
    func stalestAge() -> TimeInterval {
        var oldest: Date?
        stateQ.sync {
            if snaps.contains(where: { $0.dataAt == nil }) { oldest = nil }
            else { oldest = snaps.compactMap { $0.dataAt }.min() }
        }
        return oldest.map { -$0.timeIntervalSinceNow } ?? .infinity
    }

    // 一个 tick 只拉一个账户（数据最旧且已过退避期的那个）；force=手动刷新，全拉且无视退避
    func tick(force: Bool = false) {
        let now = Date()
        var targets: [Int] = []
        stateQ.sync {
            if refreshing { return }
            if now.timeIntervalSince(lastAttempt) < (force ? FORCE_MIN_GAP : TICK_MIN_GAP) { return }
            if force {
                targets = Array(snaps.indices)
            } else {
                if now < globalCooldown { return }
                let eligible = snaps.indices.filter { now >= snaps[$0].notBefore }
                guard let pick = eligible.min(by: {
                    (snaps[$0].dataAt ?? .distantPast) < (snaps[$1].dataAt ?? .distantPast)
                }) else { return }
                targets = [pick]
            }
            refreshing = true; lastAttempt = now
        }
        guard !targets.isEmpty else { return }
        workQ.async { self.doRefresh(targets) }
    }

    private func doRefresh(_ idxs: [Int]) {
        var results = [Int: (Block?, Block?, String?, Double?)]()  // idx -> (weekly, fable, err, retryAfter)
        for i in idxs { results[i] = Self.fetchAccount(ACCOUNTS[i]) }  // 串行，避免同瞬间双请求
        let now = Date()
        stateQ.sync {
            for (i, r) in results {
                if let err = r.2 {
                    snaps[i].error = err
                    if err == "http_429" {
                        snaps[i].backoff = snaps[i].backoff == 0 ? 300 : min(snaps[i].backoff * 2, 3600)
                        if let ra = r.3 { snaps[i].backoff = min(max(snaps[i].backoff, ra), 3600) }
                        snaps[i].notBefore = now.addingTimeInterval(snaps[i].backoff)
                        globalCooldown = max(globalCooldown, now.addingTimeInterval(60))
                    }
                } else {
                    snaps[i].error = nil
                    snaps[i].backoff = 0
                    snaps[i].notBefore = .distantPast
                    snaps[i].weekly = r.0
                    snaps[i].fable = r.1
                    snaps[i].dataAt = now
                }
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
// 颜色按“剩余”算：越少越红
func remColor(_ rem: Double) -> NSColor {
    if rem <= 10 { return .systemRed }
    if rem <= 30 { return .systemOrange }
    return .labelColor
}

// 菜单里的倒计时："1天8时" / "8时20分" / "45分"
func shortLeft(_ epoch: Double?) -> String {
    guard let e = epoch else { return "—" }
    var s = Int(e - Date().timeIntervalSince1970)
    if s <= 0 { return "已重置" }
    let d = s / 86400; s %= 86400
    let h = s / 3600;  s %= 3600
    let m = s / 60
    if d > 0 { return h > 0 ? "\(d)天\(h)时" : "\(d)天" }
    if h > 0 { return "\(h)时\(m)分" }
    return "\(m)分"
}

// 菜单栏标题里的极简倒计时："6d" / "8h" / "<1h"
func tinyLeft(_ epoch: Double?) -> String {
    guard let e = epoch else { return "?" }
    let s = Int(e - Date().timeIntervalSince1970)
    if s <= 0 { return "0" }
    if s >= 86400 { return "\(s / 86400)d" }
    if s >= 3600 { return "\(s / 3600)h" }
    return "<1h"
}

// 富文本小段
func seg(_ s: String, _ color: NSColor, _ size: CGFloat, bold: Bool = false, mono: Bool = false) -> NSAttributedString {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                    : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    return NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
}

func shortErr(_ code: String) -> String {
    switch code {
    case "http_429":      return "429"
    case "token_expired": return "Token过期"
    case "no_token":      return "无凭据"
    default:              return code
    }
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

// ---- 菜单账户行（自绘视图：容量条 + 倒计时，系统语义色自动适配深浅色） ----
final class AccountRowView: NSView {
    private let snap: AcctSnap
    private let dotColor: NSColor

    init(snap: AcctSnap, dotColor: NSColor) {
        self.snap = snap
        self.dotColor = dotColor
        super.init(frame: NSRect(x: 0, y: 0, width: 336, height: 48))
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var isFlipped: Bool { true }

    // 容量条填充色：剩得越少越警示
    private func barColor(_ rem: Double) -> NSColor {
        if rem <= 10 { return .systemRed }
        if rem <= 30 { return .systemOrange }
        return .systemGreen
    }

    @discardableResult
    private func put(_ a: NSAttributedString, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        a.draw(at: NSPoint(x: x, y: y))
        return x + a.size().width
    }

    // "Fable ▬▬▬▬▬░░ 52%"，返回结束 x
    private func drawGauge(_ name: String, _ b: Block?, _ x0: CGFloat) -> CGFloat {
        var x = put(seg(name, .secondaryLabelColor, 11), x0, 27)
        x += 7
        guard let p = b?.pct else { return put(seg("—", .tertiaryLabelColor, 11), x, 27) }
        let rem = max(0.0, min(100.0, 100.0 - p))
        let barW: CGFloat = 74
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 32, width: barW, height: 4), xRadius: 2, yRadius: 2).fill()
        let fw = barW * CGFloat(rem) / 100
        if fw >= 1 {
            barColor(rem).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 32, width: fw, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        x += barW + 7
        return put(seg("\(Int(rem))%", .labelColor, 12, bold: true, mono: true), x, 25)
    }

    override func draw(_ dirtyRect: NSRect) {
        let L: CGFloat = 14, R = bounds.width - 14

        // 第一行：身份点 + 账户名 + 在用徽章 | 右对齐：距重置 + 日期 (+降级标记)
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: L, y: 10, width: 7, height: 7)).fill()
        var x = put(seg(snap.cfg.label, .labelColor, 13, bold: true), L + 13, 5)
        if snap.active {
            let t = seg("在用", .systemGreen, 9, bold: true)
            let badge = NSRect(x: x + 6, y: 6, width: t.size().width + 10, height: 14)
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            put(t, badge.minX + 5, 8)
            x = badge.maxX
        }
        let hasData = snap.weekly != nil || snap.fable != nil
        let right = NSMutableAttributedString()
        if hasData {
            let ep = snap.fable?.resetsEpoch ?? snap.weekly?.resetsEpoch
            right.append(seg("\(shortLeft(ep))后重置", .labelColor, 12, mono: true))
            right.append(seg("  \(resetAt(ep))", .tertiaryLabelColor, 10, mono: true))
        }
        if let e = snap.error {
            var w = "  ⚠\(shortErr(e))"
            if hasData, let at = snap.dataAt { w += "·\(ageText(-at.timeIntervalSinceNow))" }
            right.append(seg(w, .systemOrange, 10))
        }
        put(right, R - right.size().width, 6)

        // 第二行：两个容量条
        if hasData {
            let end = drawGauge("Fable", snap.fable, L)
            _ = drawGauge("周", snap.weekly, end + 20)
        } else {
            put(seg(snap.error.map(errText) ?? "暂无数据", .systemRed, 12), L, 26)
        }
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
        store.tick()
        render()
        // 启动预热：45 秒后错峰拉另一个账户（tick 自动挑数据最旧的），不和首次拉取挤在同一瞬间
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.store.tick()
        }
        timer = Timer.scheduledTimer(withTimeInterval: POLL_SEC, repeats: true) { [weak self] _ in
            self?.store.tick()
            self?.render()   // 即便这轮没拉数据也刷新一下界面上的时间显示
        }
        timer?.tolerance = 10
    }

    func menuWillOpen(_ menu: NSMenu) {
        if store.stalestAge() > MENU_STALE_SEC { store.tick() }
        render()
    }

    // 菜单栏标题: 每账户 "●52·1d" —— Fable 剩余% + 距重置时间（周额度和 Fable 同时重置）
    func render() {
        let snaps = store.snapshot()
        let dot: [NSColor] = [.systemGreen, .systemBlue]
        let title = NSMutableAttributedString()
        for (i, s) in snaps.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: " ")) }
            title.append(seg("●", dot[i % dot.count], 8))
            let p = s.fable?.pct ?? s.weekly?.pct   // 没有 Fable 桶时退回周限额
            if let p = p {
                let rem = max(0, 100 - Int(p))
                let col: NSColor = s.error != nil ? .systemOrange : remColor(Double(rem))  // 橙=降级旧数据
                title.append(seg("\(rem)", col, 12, mono: true))
                title.append(seg("·\(tinyLeft(s.fable?.resetsEpoch ?? s.weekly?.resetsEpoch))",
                                 .secondaryLabelColor, 10, mono: true))
            } else {
                title.append(seg(s.error != nil ? "!" : "—",
                                 s.error != nil ? .systemRed : .secondaryLabelColor, 12))
            }
        }
        statusItem.button?.attributedTitle = title
        rebuildMenu(snaps)
    }

    func infoItem(_ s: NSAttributedString) -> NSMenuItem {
        let mi = NSMenuItem(); mi.attributedTitle = s; mi.isEnabled = true; return mi
    }

    // 每账户一个自绘视图行（容量条 + 倒计时）
    func rebuildMenu(_ snaps: [AcctSnap]) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let dotCol: [NSColor] = [.systemGreen, .systemBlue]

        for (i, s) in snaps.enumerated() {
            let item = NSMenuItem()
            item.view = AccountRowView(snap: s, dotColor: dotCol[i % dotCol.count])
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if let age = store.dataAge() {
            menu.addItem(infoItem(seg("更新于 \(ageText(age)) · 后台每小时轮询一次/账户",
                                      .tertiaryLabelColor, 11)))
        }
        add(menu, "立即刷新", #selector(doRefresh), "r")
        add(menu, "退出", #selector(quit), "q")
    }

    func add(_ menu: NSMenu, _ t: String, _ sel: Selector, _ key: String) {
        let mi = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        mi.target = self; mi.isEnabled = true; menu.addItem(mi)
    }

    @objc func doRefresh() { store.tick(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，只在菜单栏
app.run()
