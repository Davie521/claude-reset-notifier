// Claude Reset Notifier —— Claude 双账户重置监控，无后端单体版
// 一个菜单栏 App 干完所有事：读钥匙串 → 拉 Anthropic 用量 → 菜单栏展示。
// 只关注两件事：周限额(用量+重置时间) 和 Fable 周容量(用量+重置时间)。
// robust 设计：
//   - 背景轮询极懒：每 30 分钟只拉一个账户，两账户轮流（单账户 1 小时一次）；
//     打开菜单时被选账户数据超过 25 分钟旧才顺带补拉，手动刷新 5 分钟一次
//     （usage 接口限流极紧：实测持续 1 请求/分钟仍会 429，务必保持低频。
//      手动刷新一次打两个请求，节流给短了连点就能把总量推到 200+ 请求/小时）
//   - 所有请求闸门都按单调时钟计时：用户改表 / NTP 大幅校正不会把轮询永久锁死
//   - 429 按账户独立退避：max(Retry-After, 5→10→20…分钟, 上限1小时)，另有 60s 全局冷却；
//     非 429 的失败（token 过期 / 网络 / 5xx）也退避，否则坏账户每轮都吃掉唯一的拉取名额
//   - “立即刷新”尊重服务器给的 429 窗口和全局冷却，只越过我们自己加的软退避；
//     被闸门挡住时菜单项直接置灰并写明还要多久，不让用户点了没反应
//   - 拉取失败继续显示上次成功的数据(⚠ 降级标记)而不是清空。一份连一个百分比都没有的
//     200 永远按失败处理，绝不写进缓存；某个桶的百分比没了也先拒收，连着 PARSE_GIVE_UP 次
//     才认下新形状（且新形状必须还带着至少一个百分比）——保护缓存，但不把账户焊死
//   - 快照 + 退避窗口 + 最近一次错误一起落盘 state.json：重启立刻有数据，且不会
//     把失败账户的陈旧数据装成刚拉到的
//   - 菜单结构建一次就不再拆：更新只改行内容，不在菜单开着时抽掉鼠标底下的 item
//   - 界面时钟(30s)和主线程回调都挂在 common runloop 模式：菜单跟踪期间主 runloop 跑的是
//     NSEventTrackingRunLoopMode，默认模式的 Timer 在这段时间一次都不触发（多次实测一致），
//     而菜单开着恰恰是唯一需要就地更新的窗口。GCD 主队列在跟踪期间会不会被抽干，几次独立
//     实测互相矛盾（疑似和菜单是怎么打开的有关），所以干脆不赌它：common 模式按定义包含
//     跟踪模式，实测送达率也是 100%，走稳的那条
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
                                        // 周额度是慢变量，背景轮询宁懒勿勤
let RENDER_SEC: TimeInterval = 30       // 界面时钟：只重画倒计时/环，不发任何请求
let MENU_STALE_SEC: TimeInterval = 1500 // 打开菜单时被选账户数据比这旧才顺带触发一次拉取。
                                        // 必须显著大于 ACCT_MIN_GAP，否则闸门恒不成立：
                                        // 能被选中就意味着它上次尝试已是 ACCT_MIN_GAP 之前，
                                        // 数据只会更旧，闸门形同虚设，开一次菜单就是一次请求
let FORCE_MIN_GAP: TimeInterval = 300   // 手动“立即刷新”最小间隔（独立节流，不与自动拉取共享）。
                                        // 一次强刷把所有账户都拉一遍，给 30 秒的话连点就是
                                        // 4 请求/分钟，是这个接口容忍度的四倍；周额度是慢变量，
                                        // 5 分钟一次手动刷新绰绰有余
let TICK_MIN_GAP: TimeInterval = 15     // 自动拉取去重间隔（定时器与菜单打开撞车时）
let ACCT_MIN_GAP: TimeInterval = 300    // 非强刷时单账户最小尝试间隔（防频繁开菜单放大请求）
let BACKOFF_MAX: TimeInterval = 3600    // 退避上限
let PARSE_GIVE_UP = 5                   // 连续这么多次都解析不出来就认了，收下新形状。
                                        // 保护缓存不能变成把账户永久卡死：万一上游真的改了
                                        // （Fable 桶改名、或者账户没这个额度了），一直拒收会让
                                        // 这个账户永远停在旧数字上，连没坏的周限额也一起冻住。
                                        // 配合退避阶梯，5 次要横跨 ~2 小时，绝不是抖动。
let KEYCHAIN_WAIT: TimeInterval = 45    // 等 security 子进程的上限（含人手点授权弹窗的时间）
let NET_WAIT: TimeInterval = 15         // 等单个 HTTP 请求的总时长上限
let HOME = FileManager.default.homeDirectoryForCurrentUser
let CURRENT_ACCT_FILE = HOME.appendingPathComponent(".claude-current-acct")
// 状态文件固定在 Application Support（不跟二进制走：brew 装的二进制在 Cellar，升级会清空）
let STATE_DIR = HOME.appendingPathComponent("Library/Application Support/claude-reset")
let STATE_FILE = STATE_DIR.appendingPathComponent("state.json")

func j(_ v: Any?) -> Any { v ?? NSNull() }

// 读 JSON 数值统一走这里，别直接 as? NSNumber：JSON 里的 true 桥接过来也是 NSNumber，
// `as? NSNumber` 会把它读成 1.0，于是 `"percent": true` 变成一个凭空捏造的 1%，
// 还会一路走成功分支覆盖缓存。也别想着用 `is Bool` 去挡——JSON 解出来的整数
// （也就是 0/11/12 这些真实百分比）`is Bool` 同样是 true，那样会把真数字一起挡掉。
// 只有 CFBoolean 的 TypeID 分得清真假。
func jsonNum(_ v: Any?) -> Double? {
    guard let v = v else { return nil }
    if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return nil }
    return (v as? NSNumber)?.doubleValue
}

// 单调时钟。所有请求闸门都按它计时：Date() 是墙钟，用户改表或 NTP 大幅校正会把
// notBefore 留在遥远的未来，从此每一轮 tick 都跳过该账户，数据无声冻死。
// CLOCK_MONOTONIC 在 Darwin 上睡眠期间照常前进，合盖一夜醒来不会误判“刚拉过”。
func monoNow() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
let MONO_PAST = -TimeInterval.infinity   // 单调时钟里的 .distantPast

// 任何来自外部（上游 JSON / state.json）的秒数，在转成 Int 之前都要先夹住。
// Swift 的 Int(Double) 越界是 trap 不是溢出：进程 abort，launchd 按 KeepAlive 拉起来，
// 读到同一份文件再 abort——除非手删 state.json，否则出不来。
let EPOCH_MAX: Double = 4e10             // 秒级时间戳的合理上界（公元 3237 年）。卡这么紧是因为
                                         // 重置时间最多几天之后，而 tooltip 的 "MM-dd HH:mm" 不带年份：
                                         // 放一个公元 99999 年的时间戳进来，只会显示成一个平平无奇的日期
let ROW_W: CGFloat = 420                 // 账户行宽度 = 菜单宽度（见 AccountRowView）
let FOOTER_MAX: CGFloat = 337            // 页脚文字宽度上限；超了就丢掉前半句，绝不把菜单顶宽。
                                         // 穷举现有措辞能生成的所有页脚，最宽 333.6pt，夹子取 337，
                                         // 实测这个宽度下菜单始终等于 ROW_W、不会被顶宽。
                                         // 也就是说今天这个夹子不会触发（页脚永远完整显示），
                                         // 但余量只有 ~3pt——改措辞前务必重新量一遍：一旦触发，
                                         // “数据多旧”那半句会被悄悄吞掉。
                                         // （菜单开始变宽的确切阈值几次实测不一致，在 339~347pt
                                         //   之间，所以这里按最保守的那个留余量。）
func secInt(_ v: Double) -> Int {
    guard v.isFinite else { return 0 }
    return Int(max(-3.15e10, min(3.15e10, v)))   // ±1000 年，倒计时够用了
}

// 主线程回调走 common 模式：菜单跟踪期间主 runloop 跑的是 NSEventTrackingRunLoopMode，
// 而菜单开着正是就地更新唯一有意义的窗口。CFRunLoopPerformBlock(commonModes) 在多次实测里
// 送达率 100%（跟踪期间照跑，且始终在主线程）；DispatchQueue.main.async 在这段时间会不会
// 被抽干，几次独立实测结论相反——既然有一条各次实测都成立的路，就不必赌另一条。
func onMainCommon(_ block: @escaping () -> Void) {
    let rl = CFRunLoopGetMain()
    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(rl)
}

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

    // 唯一的 Block 构造入口，负责两条不变量：
    // 1) 非有限值一律丢弃。负向溢出（-1e400 / -1e309）会被 JSONSerialization 静静地
    //    解析成 -inf；正向的 1e400 反而是直接抛错，所以别拿它去验证这条路。落盘时
    //    JSONSerialization 遇到 inf 抛的是 ObjC 异常，try? 接不住，进程直接 abort——
    //    而 plist 里 KeepAlive 会立刻把它拉起来重进同一个请求，成为崩溃循环。
    // 2) 两个字段都没解析出来 = 没有数据，归一成 nil。
    //    注意这只挡住“全空”那一档：桶里还剩一个 resets_at 时 Block 依然是非 nil 的，
    //    “百分比丢了”这一档得由 fetchAccount 里的 lostPct 判定去挡（那里才知道界面
    //    要显示什么）。两处合起来才构成“空数据绝不覆盖缓存”这条不变量。
    private static func norm(_ pct: Double?, _ ep: Double?) -> Block? {
        let p = (pct?.isFinite ?? false) ? pct : nil
        // 时间戳光查 isFinite 不够，还得卡范围：Swift 里 Int(超出范围的 Double) 是 trap
        // 而不是溢出，倒计时里那句 Int(e - now) 会直接把进程打掉，KeepAlive 再拉起来再崩，
        // 用户只能手删 state.json 才脱得了身。EPOCH_MAX 之外的一律当没有。
        let e = (ep?.isFinite ?? false) && abs(ep!) < EPOCH_MAX ? ep : nil
        return (p == nil && e == nil) ? nil : Block(pct: p, resetsEpoch: e)
    }
    static func from(_ v: Any?) -> Block? {          // state.json 格式
        guard let d = v as? [String: Any] else { return nil }
        return norm(jsonNum(d["pct"]), jsonNum(d["resets_epoch"]))
    }
    static func upstream(_ v: Any?) -> Block? {      // API seven_day 格式
        guard let d = v as? [String: Any] else { return nil }
        return norm(jsonNum(d["utilization"]), isoEpoch(d["resets_at"] as? String))
    }
    static func limit(_ d: [String: Any]) -> Block? {  // API limits[] 格式
        norm(jsonNum(d["percent"]), isoEpoch(d["resets_at"] as? String))
    }
}

struct AcctSnap {
    var cfg: AcctCfg
    var active = false
    var error: String?       // 最近一次拉取的错误(nil=成功)；出错不清空旧数据，且跨重启保留
    var weekly: Block?       // 周限额(全模型)
    var fable: Block?        // Fable 周容量
    var dataAt: Date?        // 数据成功拉到的时间（墙钟：要跨重启显示“数据多旧”）
    var attemptAt = MONO_PAST   // 上次尝试拉取（单调时钟，不论成败，调度按它轮转）
    var notBefore = MONO_PAST   // 该账户的退避闸门（单调时钟）
    var backoff: TimeInterval = 0
    var rateLimited = false  // 闸门是服务器给的(429) 还是我们自己加的软退避——决定手动刷新能否越过
    var parseFails = 0       // 连续解析失败次数；到 PARSE_GIVE_UP 就收下新形状，别把账户卡死
}

// 界面需要的全部状态，一次锁读齐（见 UsageStore.uiState）
struct UIState {
    var snaps: [AcctSnap] = []        // 和下面这些字段来自同一瞬间，整帧一致
    var refreshing = false
    var forceBlocked: TimeInterval?   // nil = 现在就能手动刷新
    var gated: TimeInterval?          // 非 nil = 有账户在退避窗口里；值 = 最快多久恢复
    var allGated = false              // 是不是所有账户都被关着（决定页脚措辞）
    var oldestAge: TimeInterval?      // 最旧那个账户的数据年龄
    var missingData = false           // 有账户从来没成功拉到过
}

// 加锁盒子：URLSession 回调线程与等待方之间传结果用（信号量超时后回调可能还活着，裸变量会撕裂读写）
final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
}

// ---- 取数与缓存 ----
final class UsageStore {
    static let shared = UsageStore()
    private let stateQ = DispatchQueue(label: "state")   // 只做快速读写
    private let workQ = DispatchQueue(label: "work")     // 子进程 + 网络
    private var snaps: [AcctSnap]
    private var refreshing = false
    private var lastAttempt = MONO_PAST
    private var lastForce = MONO_PAST                    // 手动刷新独立节流
    private var globalCooldown = MONO_PAST               // 任一账户 429 后的短全局冷却
    var onUpdate: (() -> Void)?                          // 主线程回调

    private init() {
        snaps = ACCOUNTS.map { AcctSnap(cfg: $0) }
        try? FileManager.default.createDirectory(at: STATE_DIR, withIntermediateDirectories: true)
        guard let d = try? Data(contentsOf: STATE_FILE),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]]
        else { return }
        let mono = monoNow(), wall = Date().timeIntervalSince1970
        for i in snaps.indices {
            guard let e = obj[snaps[i].cfg.id] else { continue }
            snaps[i].weekly = Block.from(e["weekly"])
            snaps[i].fable = Block.from(e["fable"])
            // at 同样要挡：非有限值会让之后每一次 saveState 都被 isValidJSONObject 拦下，
            // 落盘从此静默永久停摆；而一个「有限但离谱」的值（比如 -1e300）更糟——
            // 它一路活到页脚那句 Int(t / 86400)，直接 trap 掉整个进程
            // 未来的时间戳也一并丢掉（留一天容忍时钟误差）：否则年份离谱的 at 会让
            // 页脚和 tooltip 一本正经地写“刚刚”
            if let at = jsonNum(e["at"]),
               at.isFinite, abs(at) < EPOCH_MAX, at <= wall + 86400 {
                snaps[i].dataAt = Date(timeIntervalSince1970: at)
            }
            // 上次尝试时间也跨重启保留。不然每次启动都白送一次不受节流的请求：
            // plist 里 KeepAlive 会在崩溃后立刻拉起来，一个崩溃循环就是每分钟好几个请求，
            // 远超这个接口的容忍度。恢复时把“已经过去多久”夹在 [0, ACCT_MIN_GAP]：
            // 存的时刻在未来（时钟被往回调）就当刚试过，宁可多等也不多打。
            if let aa = jsonNum(e["attempt_at"]), aa.isFinite {
                snaps[i].attemptAt = mono - min(max(0, wall - aa), ACCT_MIN_GAP)
            }
            // “有数据”和“数据的时间”必须同生共死，两边都要对齐：只剩桶没有时间时，
            // 行里画着“周 剩50%”，页脚却写“暂无数据”，反过来则是行里“暂无数据”配
            // 页脚“最旧数据 12 分钟前”——两种都是自相矛盾
            if snaps[i].weekly == nil && snaps[i].fable == nil { snaps[i].dataAt = nil }
            if snaps[i].dataAt == nil { snaps[i].weekly = nil; snaps[i].fable = nil }
            // 错误也要恢复：只恢复数据不恢复错误，重启后失败账户的陈旧数字会装成
            // 刚拉到的（无 ⚠、tooltip 无失败行），用户按一个几小时前的数字做决定
            snaps[i].error = e["error"] as? String
            snaps[i].backoff = min(max(0, jsonNum(e["backoff"]) ?? 0), BACKOFF_MAX)
            snaps[i].rateLimited = (e["rate_limited"] as? NSNumber)?.boolValue ?? false
            // 跨重启保留，否则重启一次就把"上游真的改了"的计数清零，又卡回去
            // 夹到 PARSE_GIVE_UP - 1：文件里要是躺着一个 5，重启后下一份半残响应就会被
            // 直接收下，2 小时的保护窗口整个跳过。留一次拒收给缓存当垫背。
            snaps[i].parseFails = Int(min(max(0, jsonNum(e["parse_fails"]) ?? 0), Double(PARSE_GIVE_UP - 1)))
            // 退避窗口跨重启保留：重启不等于可以无视服务器的 Retry-After。
            // 落盘的是墙钟绝对时刻，这里换算回单调时钟并夹到上限——系统时间被往前
            // 调过时文件里可能存着几个月后的时刻，原样恢复就是永久静默冻结。
            if let nb = jsonNum(e["not_before"]), nb.isFinite {
                snaps[i].notBefore = mono + min(max(0, nb - wall), BACKOFF_MAX)
            }
        }
    }

    // 一帧界面要用到的所有东西，一次锁里读齐，返回同一瞬间的快照——账户行、页脚、
    // “立即刷新”菜单项全从这一份来。拆成几次独立的读会开出真实的窗口：一次刷新恰好落在
    // 两次读之间，就会渲染出“正在刷新…”配一个已经可点的“立即刷新”，
    // 或者页脚说“最旧数据 刚刚”而行的 tooltip 还写着“2.7 小时前”。
    func uiState() -> UIState {
        // 当前账户标记要读磁盘，放在锁外
        let cur = ((try? String(contentsOf: CURRENT_ACCT_FILE, encoding: .utf8)) ?? "a")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var u = UIState()
        stateQ.sync {
            let mono = monoNow()
            u.snaps = snaps
            u.refreshing = refreshing
            // 年龄取最旧不取最新：页脚那句话盖在所有账户行上面，取最新会把
            // “B 两天没更新过”写成“更新于 刚刚”，直接骗人
            u.oldestAge = snaps.compactMap { $0.dataAt }.min().map { max(0, -$0.timeIntervalSinceNow) }
            u.missingData = snaps.contains { $0.dataAt == nil }
            // 退避情况：最快多久有账户能恢复，以及是不是全都被关着。
            // 只报“全部”是不够的——一个账户被关一小时、另一个健康时，页脚照样会理直气壮
            // 写“后台每小时轮询一次/账户”，那对被关着的那个来说是假话。
            let waits = snaps.map { max(0, $0.notBefore - mono) }
            if let soonest = waits.filter({ $0 > 0 }).min() {
                u.gated = soonest
                u.allGated = waits.allSatisfy { $0 > 0 }
            }
            // 手动刷新真正可用还要多久：三道闸门取最大（自身节流 / 全局冷却 / 全部账户
            // 都卡在服务器给的 429 窗口里）。菜单项据此置灰并写明时间，别让用户点了没反应。
            var wait = max(FORCE_MIN_GAP - (mono - lastForce), globalCooldown - mono)
            let open = snaps.indices.filter { !(snaps[$0].rateLimited && mono < snaps[$0].notBefore) }
            if open.isEmpty, let soonest = snaps.map({ $0.notBefore - mono }).min() {
                wait = max(wait, soonest)
            }
            if wait > 0 { u.forceBlocked = wait }
        }
        for i in u.snaps.indices { u.snaps[i].active = u.snaps[i].cfg.id == cur }
        return u
    }

    // 一个 tick 只拉一个账户：按“上次尝试时间”轮转（不论成败都推进，失败账户不会
    // 独占调度饿死健康账户）。staleGate 给菜单打开用：被选账户数据够新就不拉。
    // force=手动刷新：拉所有没被服务器闸门挡住的账户，独立节流。
    func tick(force: Bool = false, staleGate: TimeInterval? = nil) {
        let mono = monoNow()
        var targets: [Int] = []
        stateQ.sync {
            if refreshing { return }
            if force {
                if mono - lastForce < FORCE_MIN_GAP { return }
                // 全局冷却也要认。刚有账户吃到 429，就说明这个端点（同一个 IP）正在
                // 拒人，此时去打另一个账户只是换个 token 撞同一堵墙。
                if mono < globalCooldown { return }
                // 服务器明确说了要等（429/Retry-After）就必须等——这是最容易被连点
                // 砸穿的一条路径；我们自己给 401/网络错误加的软退避则可以越过，
                // 否则用户跑完 `claude` 刷新了 token 也得干等一小时。
                targets = snaps.indices.filter { !(snaps[$0].rateLimited && mono < snaps[$0].notBefore) }
                if targets.isEmpty { return }
                lastForce = mono
            } else {
                if mono - lastAttempt < TICK_MIN_GAP { return }
                if mono < globalCooldown { return }
                let eligible = snaps.indices.filter {
                    mono >= snaps[$0].notBefore && mono - snaps[$0].attemptAt >= ACCT_MIN_GAP
                }
                guard let pick = eligible.min(by: { snaps[$0].attemptAt < snaps[$1].attemptAt })
                else { return }
                // 闸门作用在真正要拉的账户上（而不是别的账户的新旧）。
                // 数据年龄只能用墙钟（要跨重启），所以这里单独防一手：时钟被往回调时
                // age 会是负数，按“旧”处理去拉——宁可多拉一次也不静默跳过。
                if let gate = staleGate, let at = snaps[pick].dataAt {
                    let age = -at.timeIntervalSinceNow
                    if age >= 0 && age <= gate { return }
                }
                targets = [pick]
            }
            refreshing = true
            lastAttempt = mono
            for i in targets { snaps[i].attemptAt = mono }
        }
        guard !targets.isEmpty else { return }
        onMainCommon { self.onUpdate?() }   // 立刻把“刷新中”反映到界面（菜单开着也要生效）
        workQ.async { self.doRefresh(targets, force: force) }
    }

    private func doRefresh(_ idxs: [Int], force: Bool) {
        // 串行，避免同瞬间双请求。每个账户一出结果就提交并回调，不憋到整批结束：
        // 单账户最坏 45s(钥匙串) + 15s(网络)，两个账户就是两分钟界面纹丝不动。
        // refreshing 仍然覆盖整个循环，这是有意的——这段时间里进来的 tick 就该被吞掉，
        // 而不是叠上第二批请求；代价（吞掉一次菜单打开的补拉）由“刷新中…”明说出来。
        // attemptAt 已经在 tick 里记下了，但只记在内存里。先落一次盘再去拉：
        // 下面这段最坏能卡 60 秒（45s 钥匙串 + 15s 网络），崩在里面的话这次尝试就没了，
        // 重启回来又是一次不受节流的请求——崩溃循环下就是每分钟好几个。
        saveState()
        for i in idxs {
            let r = Self.fetchAccount(ACCOUNTS[i])
            let mono = monoNow(), now = Date()
            stateQ.sync {
                var failure = r.2
                // “成功”也可能只是半份。上游合法地可以不给某个桶（这个账户本来就没有 Fable），
                // 但“本来有、这次整块不见了”是结构变了，不是账户变了——比如 scope.model 的
                // 名字改了、或者 seven_day/weekly_all 一起换了名。这个判断只能在这里做：
                // 只有这里同时看得见新响应和缓存。要拿 nil 盖掉一个已经有的好数字，一律拒收。
                if failure == nil {
                    let losesWeekly = snaps[i].weekly?.pct != nil && r.0?.pct == nil
                    let losesFable = snaps[i].fable?.pct != nil && r.1?.pct == nil
                    if losesWeekly || losesFable { failure = "err_parse" }
                }
                // 保护缓存是为了扛住抖动和改名，不是为了把账户焊死。连着 PARSE_GIVE_UP 次
                // 都是这个形状，就说明上游是真变了：收下它，让界面回到能继续更新的状态
                // （否则一个 Fable 桶改名会把周限额也一起冻住，而周限额是无辜的）。
                // 但收之前必须确认新形状**至少还带着一个百分比**：一份什么都没有的响应
                // 永远不是"新常态"，它就是坏的。少了这个条件，这条"认命"通道就等于给
                // 缓存清空开了张延迟 2 小时的支票——正是这整套东西要防的那件事。
                if failure == "err_parse" && snaps[i].parseFails >= PARSE_GIVE_UP
                    && (r.0?.pct != nil || r.1?.pct != nil) { failure = nil }
                if let err = failure {
                    snaps[i].error = err
                    // 只数"连着"的解析失败：中间夹了个 429 或者网络错误，就不该继续
                    // 往"认命"那条线上累加——那不是同一个形状连续出现
                    snaps[i].parseFails = (err == "err_parse") ? snaps[i].parseFails + 1 : 0
                    let server = (err == "http_429")
                    if server {
                        // Retry-After 是上游给的字符串，Double("inf")/Double("nan") 都能解析成功。
                        // NaN 尤其阴：Swift 的 max(x, nan) 直接返回 x，会把一个刚吃到 429 的
                        // 账户的退避抹成 0——比这个头压根不存在还糟。非有限或非正一律当没给。
                        // 再给个 60 秒地板：Retry-After: 1e-320 是个合法的有限正数，
                        // 照单全收会让退避比这个头压根不存在时还弱（默认 300s）
                        let ra: Double? = (r.3?.isFinite == true && r.3! > 0) ? max(r.3!, 60) : nil
                        if force {
                            // 手动重试失败不加倍退避——用户连点不应把退避推到一小时
                            snaps[i].backoff = min(max(snaps[i].backoff, ra ?? 300), BACKOFF_MAX)
                        } else {
                            snaps[i].backoff = snaps[i].backoff == 0 ? 300 : min(snaps[i].backoff * 2, BACKOFF_MAX)
                            if let ra = ra { snaps[i].backoff = min(max(snaps[i].backoff, ra), BACKOFF_MAX) }
                        }
                        globalCooldown = max(globalCooldown, mono + 60)
                    } else {
                        // 非 429 也要退避：闲置账户 token 长期过期是常态，不退避就等于
                        // 每一轮的唯一名额有一半永远浪费在一个必定 401 的请求上，
                        // 健康账户的实际刷新频率被砍半。手动刷新可以越过它。
                        snaps[i].backoff = snaps[i].backoff == 0 ? 300 : min(snaps[i].backoff * 2, BACKOFF_MAX)
                    }
                    snaps[i].rateLimited = server
                    snaps[i].notBefore = mono + snaps[i].backoff
                } else {
                    snaps[i].error = nil
                    snaps[i].backoff = 0
                    snaps[i].rateLimited = false
                    snaps[i].parseFails = 0
                    snaps[i].notBefore = MONO_PAST
                    snaps[i].weekly = r.0
                    snaps[i].fable = r.1
                    snaps[i].dataAt = now
                }
            }
            saveState()
            onMainCommon { self.onUpdate?() }
        }
        stateQ.sync { refreshing = false }
        onMainCommon { self.onUpdate?() }
    }

    private func saveState() {
        var obj = [String: Any]()
        stateQ.sync {
            let mono = monoNow(), wall = Date().timeIntervalSince1970
            for s in snaps {
                // 每个账户都写，不再只写“拉到过数据”的：退避窗口对一个从没成功过、
                // 正在被服务器拒绝的账户最重要，而它恰好没有 dataAt。
                var e: [String: Any] = [
                    "backoff": s.backoff,
                    "rate_limited": s.rateLimited,
                    "error": j(s.error),
                    // 已经过去多久，夹在 [0, ACCT_MIN_GAP] 后换算成墙钟绝对时刻
                    "attempt_at": wall - min(max(0, mono - s.attemptAt), ACCT_MIN_GAP),
                    "parse_fails": s.parseFails,
                ]
                // 没有生效中的退避窗口就干脆不写这个键。写成“当前时刻”看着无害，但存盘到
                // 重启之间时钟要是被往回调，它就成了一个未来时刻，白白把健康账户关进闸门。
                // notBefore 是单调时钟，写盘时换算成墙钟绝对时刻。
                if s.notBefore > mono { e["not_before"] = wall + (s.notBefore - mono) }
                if let at = s.dataAt {
                    e["at"] = at.timeIntervalSince1970
                    e["weekly"] = j(s.weekly?.dict)
                    e["fable"] = j(s.fable?.dict)
                }
                obj[s.cfg.id] = e
            }
        }
        // 这道 guard 是承重的，不是装饰：JSONSerialization 遇到 inf/NaN 抛的是 ObjC 异常，
        // try? 接不住，会直接 abort 整个进程，而 plist 里的 KeepAlive 会立刻把它拉起来重进
        // 同一条路——崩溃循环。上游数值由 Block.norm 过滤，本地 state.json 里的
        // at/backoff/not_before 由 init 过滤，这里兜住所有还没想到的来源。
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // 目录每次写前都确认一遍，不是只在 init 里建一次：它要是在进程活着的时候被
        // 删掉或换走，只在启动时建就意味着这个进程剩下的整条命都再也写不进去了
        try? FileManager.default.createDirectory(at: STATE_DIR, withIntermediateDirectories: true)
        try? d.write(to: STATE_FILE, options: .atomic)
    }

    // 解析：以 limits 数组为准（weekly_all=周限额，weekly_scoped=Fable 桶），缺失时退回 seven_day
    static func parseUsage(_ obj: [String: Any]) -> (Block?, Block?) {
        var weekly = Block.upstream(obj["seven_day"])
        var fable: Block?
        if let limits = obj["limits"] as? [[String: Any]] {
            var scoped: [[String: Any]] = []
            for l in limits {
                switch l["kind"] as? String {
                // limits 桶只有在真的带了百分比时才顶掉 seven_day 那份；一个只剩
                // resets_at 的桶（字段改名/为 null）非 nil，直接 ?? 会把好数据换成空壳
                case "weekly_all":
                    if let b = Block.limit(l), b.pct != nil || weekly?.pct == nil { weekly = b }
                case "weekly_scoped": scoped.append(l)
                default: break
                }
            }
            func modelName(_ l: [String: Any]) -> String {
                (((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String) ?? ""
            }
            // 只认名字匹配 Fable 的桶；匹配不上就留空（UI 标签写死是 Fable，不能拿别的模型的桶冒充）
            let pick = scoped.first { modelName($0).localizedCaseInsensitiveContains("fable") }
            fable = pick.flatMap(Block.limit)
        }
        return (weekly, fable)
    }

    static func fetchAccount(_ cfg: AcctCfg) -> (Block?, Block?, String?, Double?) {
        let (token, kcErr) = readToken(cfg.keychain)
        guard let token = token else { return (nil, nil, kcErr ?? "no_token", nil) }
        var req = URLRequest(url: USAGE_URL)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BETA_HEADER, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-reset-widget/2.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        let out = Locked<(Block?, Block?, String?, Double?)>((nil, nil, "err_timeout", nil))
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil { out.set((nil, nil, "err_network", nil)); return }
            guard let http = resp as? HTTPURLResponse else { out.set((nil, nil, "err_network", nil)); return }
            if http.statusCode == 401 { out.set((nil, nil, "token_expired", nil)); return }
            if http.statusCode == 429 {
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                out.set((nil, nil, "http_429", ra)); return
            }
            guard http.statusCode == 200 else {
                out.set((nil, nil, "http_\(http.statusCode)", nil)); return
            }
            // 200 但正文不是预期 JSON，和状态码错误不是一回事，单独报
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                out.set((nil, nil, "err_body", nil)); return
            }
            let (w, f) = parseUsage(obj)
            // 判空必须落在界面真正要显示的那个值——百分比——上，只看 Block 在不在是不够的：
            // 桶还在、resets_at 也还在、唯独 percent 改了名或换成字符串时，Block 是非 nil 的，
            // 于是一个 pct=nil 的“成功”顺着成功分支覆盖并落盘，用户最后一份准数字永久没了。
            // 这类响应一律按失败处理：保住缓存、挂上 ⚠、让错误文案说清楚。
            // 只钉百分比、不钉重置时间，这个不对称是故意的：真实响应里 Fable 桶
            // 确实会出现 pct 有值而 resets_at 为 null（本机 state.json 里就有
            // {"pct":0,"resets_epoch":null}）。要求两个字段都在的话，这类账户会永远
            // 卡在 err_parse 再也刷不出数据。缺重置时间由 resetEpoch() 回退到周限额兜着，
            // 缺百分比才是没得救、必须整条拒收的那种。
            // 这里只判一件和缓存无关的事：整份响应里一个百分比都没有。那种响应对界面
            // 毫无用处，收不收都一样坏，直接算失败。
            // "某个桶丢了百分比" 是缓存相关的判断（有没有东西可丢只有缓存知道），
            // 放在 doRefresh 里做——搁这儿做会变成一条无状态的拒收，
            // 无论收敛与否都会一直触发，把账户锁死在 5 拒 1 收的死循环里。
            // 解析结果照常回传，让 doRefresh 拿得到新形状。
            if w?.pct == nil && f?.pct == nil { out.set((w, f, "err_parse", nil)); return }
            out.set((w, f, nil, nil))
        }
        task.resume()
        // timeoutInterval 是空闲超时；这里兜一个总时长上限，超了就取消任务（不留孤儿请求）。
        // 直接返回 err_timeout，不读 out：cancel 会让回调抢着写入 err_network，
        // 同一次超时报出来的错误码会飘。
        if sem.wait(timeout: .now() + NET_WAIT) == .timedOut {
            task.cancel()
            return (nil, nil, "err_timeout", nil)
        }
        return out.get()
    }

    // 返回 (token, 错误码)。失败原因必须分开报：超时 / 拒绝授权 / 没这一项 / JSON 变了
    // 全部塞进 "no_token"，用户就会拿着 `security dump-keychain` 去找一条明明存在的凭据。
    static func readToken(_ service: String) -> (String?, String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return (nil, "kc_spawn") }
        // 45s：给钥匙串授权弹窗留出人手点击的时间（5s 会把弹窗杀掉，用户永远来不及授权）
        if sem.wait(timeout: .now() + KEYCHAIN_WAIT) == .timedOut {
            p.terminate()
            try? pipe.fileHandleForReading.close()   // 不然每超时一次漏一个读端 fd
            return (nil, "kc_timeout")
        }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            // 44 = errSecItemNotFound，真的没有这条；其余是权限/钥匙串本身的问题
            return (nil, p.terminationStatus == 44 ? "no_token" : "kc_exit_\(p.terminationStatus)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return (nil, "kc_bad_json")
        }
        let oauth = obj["claudeAiOauth"] as? [String: Any] ?? obj
        guard let t = oauth["accessToken"] as? String, !t.isEmpty else { return (nil, "kc_no_field") }
        return (t, nil)
    }
}

// ---- 展示工具 ----
// 颜色按“剩余”算：越少越警示。向文字色混 35% 压饱和度——
// 大号粗体数字用纯 systemOrange/Red 在浅色菜单里太刺眼
func remColor(_ rem: Double) -> NSColor {
    let base: NSColor
    if rem <= 10 { base = .systemRed }
    else if rem <= 30 { base = .systemOrange }
    else { return .labelColor }
    return base.blended(withFraction: 0.35, of: .labelColor) ?? base
}

// 秒数转“至少 1 分钟”的整数分钟，给等待提示用
// 走 secInt 而不是裸 Int()：今天所有调用点传进来的都是夹过的 (0,3600]，但这条规矩
// （外来秒数转 Int 之前必须夹）不该在这里破例——将来有人让一个没夹的时长流到这里，
// 换来的就是本文件其他地方拼命在防的那种崩溃循环
func mins(_ t: TimeInterval) -> Int { max(1, secInt(ceil(t / 60))) }

// 菜单里的倒计时："1天8时" / "8时20分" / "45分"
func shortLeft(_ epoch: Double?, now: Double = Date().timeIntervalSince1970) -> String {
    guard let e = epoch else { return "—" }
    var s = secInt(e - now)
    if s <= 0 { return "已重置" }
    let d = s / 86400; s %= 86400
    let h = s / 3600;  s %= 3600
    let m = s / 60
    if d > 0 { return h > 0 ? "\(d)天\(h)时" : "\(d)天" }
    if h > 0 { return "\(h)时\(m)分" }
    return "\(max(1, m))分"   // 不足一分钟也说“1分”，跟菜单栏的 tinyLeft 口径一致
}

// 菜单栏标题里的极简倒计时："6d" / "8h" / "45m"；已过重置点显示 ✓（额度已恢复）
func tinyLeft(_ epoch: Double?) -> String {
    guard let e = epoch else { return "?" }
    let s = secInt(e - Date().timeIntervalSince1970)
    if s <= 0 { return "✓" }
    if s >= 86400 { return "\(s / 86400)d" }
    if s >= 3600 { return "\(s / 3600)h" }
    return "\(max(1, s / 60))m"
}

// 有效剩余量：重置时刻一过，额度实际已恢复 100%——不能拿旧数据的红环吓人
func effectiveRem(_ b: Block?) -> Double? {
    guard let b = b, let p = b.pct else { return nil }
    // 判定用和 shortLeft/tinyLeft 一模一样的谓词：写成 `e <= now` 的话，重置前最后
    // 不到一秒里，行里已经写“已重置”、菜单栏已经是 ✓，环却还是空的、数字还是旧的
    if let e = b.resetsEpoch, secInt(e - Date().timeIntervalSince1970) <= 0 { return 100 }
    return max(0.0, min(100.0, 100.0 - p))
}

// 重置时间优先看 Fable 桶，该桶没给时间才退回周限额。回退必须在 epoch 这一层做：
// 写成 `(fable ?? weekly)?.resetsEpoch` 时，一个有 pct 却缺 resets_at 的 Fable 桶
// 会连带把周限额那个好端端的重置时间一起吞掉，界面上就成了 "?" / "—"。
func resetEpoch(_ s: AcctSnap) -> Double? { s.fable?.resetsEpoch ?? s.weekly?.resetsEpoch }

// 菜单行的重置说明；哨兵情况（已过/未知）单独成句，不与"后重置"拼接出乱语。
// now 只取一次再传下去，判空也用和 shortLeft 一模一样的谓词：分两次取 Date() 时，
// 重置时刻落在两次之间（或差值不足 1 秒被 secInt 截成 0）就会拼出“已重置后重置”——
// 重置前的最后一秒，每次都会这样。
func resetPhrase(_ epoch: Double?) -> String {
    guard let e = epoch else { return "—" }
    let now = Date().timeIntervalSince1970
    if secInt(e - now) <= 0 { return "已重置" }
    return shortLeft(e, now: now) + "后重置"
}

// 富文本小段
func seg(_ s: String, _ color: NSColor, _ size: CGFloat, bold: Bool = false, mono: Bool = false) -> NSAttributedString {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                    : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    return NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
}

// 菜单栏用的迷你余量同心双环：外环=周限额，内环=Fable。
// 全程单色 labelColor（菜单栏惯例，壁纸染色/深浅切换下都清晰），不做橙/红警示：
// 额度本来就是拿来花完的，剩得少是常态不是事故，环只当油量表不当告警器；
// 身份由内外位置编码，也不配身份色。菜单里的数字警色(remColor)另说——那里看的是细节。
// rem=剩余%(0-100)，从 12 点顺时针消耗，nil(无数据)只画淡轨道
func ringImage(outerRem: Double?, innerRem: Double?, size: CGFloat = 15) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let c = NSPoint(x: size / 2, y: size / 2)
        let lw: CGFloat = 2
        func ring(_ radius: CGFloat, _ rem: Double?) {
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()
            guard let rem = rem, rem > 2 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(1, rem / 100)), clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            arc.stroke()
        }
        let outerR = (size - lw) / 2
        ring(outerR, outerRem)            // 外环：周限额
        ring(outerR - lw - 1, innerRem)   // 内环：Fable（留 1pt 缝隙防糊成一团）
        return true
    }
}

func resetAt(_ epoch: Double?) -> String {
    guard let e = epoch else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")  // 固定 24 小时制，不被系统 12 小时偏好改写
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: e))
}

func ageText(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "时间异常" }
    if t < 90 { return "刚刚" }
    if t < 5400 { return "\(Int(t / 60)) 分钟前" }
    // 超过两天就按天说：一个长期失败的账户会攒出 "240.0 小时前" 这种既难读、
    // 又能把页脚撑到把整个菜单顶宽的字符串。天数要夹一下再转 Int——
    // 这里是 state.json 里一个离谱的 at 最终会走到的地方，越界的 Int() 是 trap。
    if t < 172800 { return String(format: "%.1f 小时前", t / 3600) }
    return "\(Int(min(t / 86400, 99999))) 天前"
}

// hasData=false 时不能说“已保留旧数据”——那种情况下这句话本身就是整行的全部内容，
// 底下一个数字都没有，等于当着用户的面说了句假话
// hasData 故意不给默认值：给了的话，将来任何一个忘了传的调用点都会悄悄退回
// “没数据却说已保留旧数据”那句假话，而这个参数就是为了堵它才加的。让编译器盯着。
func errText(_ code: String, hasData: Bool) -> String {
    switch code {
    case "err_parse": return hasData ? "响应结构异常(已保留旧数据)" : "响应结构异常"
    case "token_expired": return "Token 过期 · 跑一次 claude 刷新"
    case "no_token":      return "钥匙串里没有这条凭据"
    case "kc_timeout":    return "钥匙串授权超时 · 解锁钥匙串后重试"
    case "kc_spawn":      return "无法调用 /usr/bin/security"
    case "kc_bad_json":   return "钥匙串凭据不是预期的 JSON"
    case "kc_no_field":   return "凭据里没有 accessToken"
    case "http_429":      return "上游限流(429)"
    case "err_body":      return "响应不是预期的 JSON"
    case "err_network":   return "网络不可达"
    case "err_timeout":   return "请求超时"
    default:
        if code.hasPrefix("kc_exit_") { return "钥匙串读取失败(退出码 \(code.dropFirst(8)))" }
        return "拉取失败: \(code)"
    }
}

// ---- 菜单账户行（单行自绘视图，信息最小编码） ----
// 冗余全部砍掉：数字颜色即严重度（不再画条）；在用状态编码进身份点（实色 vs 半透明）；
// 绝对日期/数据年龄/错误详情放 tooltip，悬停即见，平时零占用。
final class AccountRowView: NSView {
    private var snap: AcctSnap
    private let dotColor: NSColor

    init(snap: AcctSnap, dotColor: NSColor) {
        self.snap = snap
        self.dotColor = dotColor
        // 行宽决定整个菜单的宽度：菜单取所有 item 里最宽的那个。行必须是最宽的那个，
        // 否则页脚一变长就会在菜单开着的当口把整个菜单撑开重排（实测确实会跳），很扎眼。
        // 页脚那边有 FOOTER_MAX 兜着，保证永远不越过这个宽度。
        super.init(frame: NSRect(x: 0, y: 0, width: ROW_W, height: 26))
        refreshTip()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var isFlipped: Bool { true }

    // 就地更新，不重建 item：菜单可能正开着，鼠标可能正压在这一行上
    func update(_ s: AcctSnap) {
        snap = s
        refreshTip()
        needsDisplay = true
    }

    private func refreshTip() {
        var tip = ""
        if let ep = resetEpoch(snap) { tip += "重置时间 \(resetAt(ep))" }
        if let at = snap.dataAt {
            tip += (tip.isEmpty ? "" : "\n") + "数据更新于 \(ageText(max(0, -at.timeIntervalSinceNow)))"
        }
        if let e = snap.error {
            let has = snap.weekly != nil || snap.fable != nil
            tip += (tip.isEmpty ? "" : "\n") + "上次拉取失败：\(errText(e, hasData: has))"
        }
        toolTip = tip.isEmpty ? nil : tip
    }

    @discardableResult
    private func put(_ a: NSAttributedString, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        a.draw(at: NSPoint(x: x, y: y))
        return x + a.size().width
    }
    private func putRight(_ a: NSAttributedString, _ right: CGFloat, _ y: CGFloat) {
        a.draw(at: NSPoint(x: right - a.size().width, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let R = bounds.width - 14

        // 身份点 + 账户名：在用=实色点+全亮字，闲置=半透明点+次级灰字
        let on = snap.active
        (on ? dotColor : dotColor.withAlphaComponent(0.35)).setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: 9.5, width: 7, height: 7)).fill()
        let lx = put(seg(snap.cfg.label, on ? .labelColor : .secondaryLabelColor, 13, bold: true), 27, 4.5)

        let hasData = snap.weekly != nil || snap.fable != nil
        // 账户级状态标记跟着账户字母走，不混进数据列
        if snap.error != nil && hasData { put(seg("⚠", .systemOrange, 9), lx + 3, 7.5) }
        guard hasData else {
            put(seg(snap.error.map { errText($0, hasData: false) } ?? "暂无数据", .systemRed, 12), 66, 5.5)
            return
        }

        // 两列数字：标签固定 x，数字右对齐固定右缘（跨行对齐）；颜色即严重度
        func gauge(_ name: String, _ b: Block?, _ labelX: CGFloat, _ numRight: CGFloat) {
            put(seg(name, .secondaryLabelColor, 11), labelX, 7)
            guard let rem = effectiveRem(b) else { putRight(seg("—", .secondaryLabelColor, 12), numRight, 6); return }
            putRight(seg("剩\(Int(rem))%", remColor(rem), 13, bold: true, mono: true), numRight, 4.5)
        }
        gauge("Fable", snap.fable, 66, 156)
        gauge("周", snap.weekly, 176, 248)

        // 右缘：距重置倒计时。常见最长 "20时47分后重置" 实测 94px（起点 311）；
        // 能构造出来的最长是重置时刻贴着 EPOCH_MAX 的 "364583天8时后重置"，117px、起点 289。
        // 两种都离周列的右缘(248)有 ≥41px，撞不上。
        putRight(seg(resetPhrase(resetEpoch(snap)), .labelColor, 12, mono: true), R, 5.5)
    }
}

// ---- App ----
class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timers: [Timer] = []
    var rowViews: [AccountRowView] = []
    var footerItem: NSMenuItem?
    var refreshItem: NSMenuItem?
    let store = UsageStore.shared

    // 一律用 common 模式挂到主 runloop：Timer.scheduledTimer 只进 .default 模式，
    // 菜单一打开（NSEventTrackingRunLoopMode）就彻底停摆，实测 tracking 期间 0 次触发
    @discardableResult
    func every(_ sec: TimeInterval, repeats: Bool = true, _ tol: TimeInterval,
               _ body: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: sec, repeats: repeats) { _ in body() }
        t.tolerance = tol
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
        return t
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⟳"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        buildMenu(menu, store.uiState().snaps)
        store.onUpdate = { [weak self] in self?.render() }
        store.tick()
        render()
        // 启动预热：45 秒后错峰拉另一个账户（tick 自动挑数据最旧的），不和首次拉取挤在同一瞬间
        every(45, repeats: false, 5) { [weak self] in self?.store.tick() }
        every(POLL_SEC, 10) { [weak self] in self?.store.tick() }
        // 界面时钟和网络节奏彻底分开：倒计时、"✓"、环的满格都是随时间自己在变的，
        // 挂在 30 分钟的拉取定时器上，就会出现额度早已恢复而菜单栏还挂着 "15m" 的半小时空窗。
        every(RENDER_SEC, 5) { [weak self] in self?.render() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        store.tick(staleGate: MENU_STALE_SEC)
        render()
    }

    // 菜单结构只建一次（账户数量是编译期常量）。之后一律就地更新行内容，
    // 绝不 removeAllItems 重建：拉取是异步的，回调走 common 模式，随时可能落在菜单
    // 正开着的时候，把鼠标底下的 item 在 mouse-down 与 mouse-up 之间换掉——
    // 点“立即刷新”会点成“退出”。
    func buildMenu(_ menu: NSMenu, _ snaps: [AcctSnap]) {
        menu.removeAllItems()
        rowViews = []
        let dotCol: [NSColor] = [.systemGreen, .systemBlue]
        for (i, s) in snaps.enumerated() {
            let v = AccountRowView(snap: s, dotColor: dotCol[i % dotCol.count])
            let item = NSMenuItem()
            item.view = v
            rowViews.append(v)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let f = NSMenuItem()
        f.isEnabled = false   // 纯信息行：可点会跟着高亮、点一下还把菜单关了
        footerItem = f
        menu.addItem(f)
        refreshItem = add(menu, "立即刷新", #selector(doRefresh), "r")
        add(menu, "退出", #selector(quit), "q")
    }

    // 菜单栏标题: 每账户 = 余量同心双环(外=周限额, 内=Fable) + 距重置时间(文字主角)，如 "◔ 5d  ◑ 21h"
    // 左 A 右 B 靠位置区分
    func render() {
        let u = store.uiState()
        let snaps = u.snaps
        let title = NSMutableAttributedString()
        for (i, s) in snaps.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ")) }
            let remW = effectiveRem(s.weekly)
            let remF = effectiveRem(s.fable)
            let att = NSTextAttachment()
            att.image = ringImage(outerRem: remW, innerRem: remF)
            att.bounds = CGRect(x: 0, y: -3, width: 15, height: 15)
            title.append(NSAttributedString(attachment: att))
            // 倒计时仍以 Fable 桶为准（该桶没给时间才退回周），文字和取值同源
            // 标题不放警标：闲置账户 token 过期是常态（数据照样够准），错误详情在菜单行/tooltip
            if (remF ?? remW) != nil {
                title.append(seg(" \(tinyLeft(resetEpoch(s)))", .labelColor, 13, mono: true))
            } else {
                title.append(seg(" —", .labelColor, 13))
            }
        }
        statusItem.button?.attributedTitle = title

        // 只就地更新，永不重建。这里不留“数量变了就 buildMenu”的兜底分支：账户数量是编译期
        // 常量，那条分支永远走不到，但它是这个回调路径上最后一条能 removeAllItems 的路——
        // 实测重建并不会关掉正在跟踪的菜单，只会把鼠标底下的 item 换掉，正是原来那个 bug。
        for (i, s) in snaps.enumerated() where i < rowViews.count { rowViews[i].update(s) }
        footerItem?.attributedTitle = seg(footerText(u), .secondaryLabelColor, 11)

        // 点了没反应是最差的反馈。三道闸门（手动节流/全局冷却/服务器 429）任一挡住，
        // 就直接置灰并把还要等多久写在标题上。
        let blocked = u.refreshing ? nil : u.forceBlocked
        refreshItem?.title = u.refreshing ? "刷新中…"
                                         : (blocked.map { "立即刷新（约 \(mins($0)) 分钟后可用）" } ?? "立即刷新")
        refreshItem?.isEnabled = !u.refreshing && blocked == nil
    }

    // 页脚这句话盖在所有账户行上面，写的必须是对最旧那一行也成立的话
    func footerText(_ u: UIState) -> String {
        // “每账户”不能省：强刷是串行走完所有账户的，这条横幅可以挂到两倍时长
        if u.refreshing { return "正在刷新…（读钥匙串每账户最长等 45 秒）" }
        let head: String
        if let age = u.oldestAge {
            head = u.missingData ? "部分无数据 · 其余最旧 \(ageText(age))"
                                 : "最旧数据 \(ageText(age))"
        } else {
            head = "暂无数据"
        }
        // 退避提示必须排在“暂无数据”之后而不是被它短路掉：一个账户都没成功过、而且全在
        // 退避窗口里，正是最需要解释“为什么打开菜单也不拉”的时候。措辞只说“自动轮询”：
        // 手动刷新能越过软退避，写成“全部退避中”会和下面那个还亮着的菜单项自相矛盾。
        // 只说“轮询”：手动刷新能越过软退避，写成“全部退避中”会和下面那个还亮着的
        // 菜单项自相矛盾
        // 两种说法同宽，换措辞不会改变页脚的最大宽度
        let tail = u.gated.map { (u.allGated ? "轮询退避中，约 " : "部分退避中，约 ") + "\(mins($0)) 分钟后恢复" }
            ?? "后台每小时轮询一次/账户"
        let full = head + " · " + tail
        // 量出来再决定：页脚一旦比行宽，就会在菜单正开着的时候把整个菜单撑开重排。
        // 与其赌措辞永远够短，不如超了就丢掉前半句——“为什么不动”比“数据多旧”更该留。
        return seg(full, .labelColor, 11).size().width <= FOOTER_MAX ? full : tail
    }

    @discardableResult
    func add(_ menu: NSMenu, _ t: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        mi.target = self; mi.isEnabled = true; menu.addItem(mi)
        return mi
    }

    @objc func doRefresh() { store.tick(force: true) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，只在菜单栏
app.run()
