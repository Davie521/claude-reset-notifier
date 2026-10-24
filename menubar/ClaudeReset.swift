// SPDX-License-Identifier: Apache-2.0
// Claude Reset Notifier —— Claude 多账户重置监控，无后端单体版
// 一个菜单栏 App 干完所有事：读钥匙串 → 拉 Anthropic 用量 → 菜单栏展示。
// 关注三件事：周限额、Fable 周容量（各含用量 + 重置时间），以及只在下拉菜单里显示的 5 小时窗口。
// robust 设计：
//   - 背景轮询极懒：每 30 分钟只拉一个账户，各账户轮流（N 个账户则每个 N×30 分钟一次）；
//     打开菜单时被选账户数据超过 25 分钟旧才顺带补拉，手动刷新 5 分钟一次
//     （usage 接口限流极紧：实测持续 1 请求/分钟仍会 429，务必保持低频。
//      手动刷新一次每个账户打一个请求，节流给短了连点就能把总量推到 200+ 请求/小时）
//   - 所有请求闸门都按单调时钟计时：用户改表 / NTP 大幅校正不会把轮询永久锁死
//   - 429 按账户独立退避：max(Retry-After, 5→10→20…分钟, 上限1小时)，另有 60s 全局冷却；
//     非 429 的失败（token 过期 / 网络 / 5xx）也退避，否则坏账户每轮都吃掉唯一的拉取名额
//   - “立即刷新”尊重服务器给的 429 窗口和全局冷却，只越过我们自己加的软退避；
//     被闸门挡住时菜单项直接置灰并写明还要多久，不让用户点了没反应
//   - token 过期的账户每分钟看一眼钥匙串条目的修改时间（只查属性、不发请求），Claude Code 一换新 token
//     就立刻重拉，不等软退避走完
//   - 拉取失败继续显示上次成功的数据(⚠ 降级标记)而不是清空。一份连一个百分比都没有的
//     200 永远按失败处理，绝不写进缓存；某个桶的百分比没了也先拒收（套餐是 Pro 时 Fable 桶除外），
//     连着 PARSE_GIVE_UP 次才认下新形状（且新形状必须还带着至少一个百分比）——保护缓存，但不把账户焊死
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
import CryptoKit

// ---- 配置 ----
// 账户自动发现，不用改源码：Claude Code 每个配置目录在钥匙串里存一条 OAuth 凭据——默认目录
// ~/.claude 是 "Claude Code-credentials"，其他目录（用 CLAUDE_CONFIG_DIR 指过去的）是
// "Claude Code-credentials-" + sha256(目录绝对路径) 的前 8 位（2026-10-14 在三个目录上核对过）。
// 所以扫 ~/.claude 和 ~/.claude-* 这些目录、只留钥匙串里真有凭据的：~/.claude 记作 A，
// ~/.claude-b 记作 B，以此类推。~/.claude-mem 这类不是配置目录的，钥匙串里没有对应条目，自然被排除；
// 反过来，钥匙串里有、目录已经删掉的孤儿条目也不会冒出来。
// 只在启动时扫一次（菜单行数启动时就定了，见 render），新登一个账户后重启看板生效。
// CLAUDE_CONFIG_DIR 指到 ~/.claude-* 以外的位置不会被发现。账户多了菜单栏会变长（每个约 50pt），
// 刘海屏上放不下时系统会把整个图标藏起来；页脚的轮询间隔按账户数自动算，启动预热最多两个账户。
struct AcctCfg { let id: String; let label: String; let keychain: String; var dir = "~/.claude" }

// 钥匙串里有没有这条（只查属性、不取密码，不会弹授权框）。只有退出码 44（errSecItemNotFound）才算「没有」；
// 其余失败（超时 / 起不了进程 / 钥匙串本身出错）返回 nil，调用方按「有」处理：多一行显示错误，
// 好过把一个真账户悄悄藏掉——发现只在启动时做一次，藏掉了就一直藏到下次重启（Codex 2026-10-14）。
func keychainHas(_ service: String) -> Bool? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let sem = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in sem.signal() }
    do { try p.run() } catch { return nil }
    if sem.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return nil }
    switch p.terminationStatus {
    case 0: return true
    case 44: return false
    default: return nil
    }
}

// 钥匙串条目的修改时间（mdat，秒级），同样只查属性、不取密码。Claude Code 每次刷新 token 都会重写自己那一条，
// 所以凭据失效的账户靠它判断「换没换新 token」，不用发请求去试。读不到（没这条 / 超时 / 输出格式变了）
// 一律返回 nil，调用方当「没变」处理：最坏退回原来的退避节奏，不会因此多发请求。
// 输出里那一行长这样：    "mdat"<timedate>=0x32303236...5A00  "20261024132403Z\000"
let mdatFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMddHHmmss"
    return f
}()
func keychainMtime(_ service: String) -> Double? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    let sem = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in sem.signal() }
    do { try p.run() } catch { return nil }
    if sem.wait(timeout: .now() + 5) == .timedOut {
        p.terminate()
        try? pipe.fileHandleForReading.close()
        return nil
    }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0, let out = String(data: d, encoding: .utf8),
          let line = out.split(separator: "\n").first(where: { $0.contains("\"mdat\"<timedate>") }),
          let r = line.range(of: #""\d{14}Z"#, options: .regularExpression),
          let t = mdatFmt.date(from: String(line[r].dropFirst().prefix(14)))?.timeIntervalSince1970,
          t.isFinite, abs(t) < EPOCH_MAX else { return nil }
    return t
}

// state.json 的键（也是 ~/.claude-current-acct 里写的那个字母）。必须只由这一个目录自己决定：
// 按出现顺序加序号、或拿「已被占用」去挑，别的目录一增删，键就会漂、读到别人的额度和退避状态
// （Codex 2026-10-14 两轮）。所以分成两套互不相交的名字：
// - 后缀只含小写字母、数字、-、_ 且不是默认目录占着的 a：直接用后缀（b、c…，和以前手写配置时一致，老缓存直接接上）
// - 其余（带大写、带别的符号、或就是 a）：用 "#" + 路径哈希前 8 位。普通键永远不含 #，两套不会撞
func accountID(suffix: String, hash: String) -> String {
    let plainOK = suffix != "a" && !suffix.isEmpty && suffix.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
    }
    return plainOK ? suffix : "#" + hash.prefix(8)
}

func discoverAccounts() -> [AcctCfg] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // 默认目录 ~/.claude 也按钥匙串判断：只用 ~/.claude-work 这类目录的人不该看到一个不存在的 A，
    // 还白占轮询名额（Codex 2026-10-14）。一个账户都找不到时在最后补回 A，让那一行告诉你「钥匙串里没有这条凭据」
    let defaultAcct = AcctCfg(id: "a", label: "A", keychain: "Claude Code-credentials")
    var out = (keychainHas(defaultAcct.keychain) ?? true) ? [defaultAcct] : []
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
        .filter { $0.hasPrefix(".claude-") && $0.count > ".claude-".count }
        .sorted()
    for name in names {
        var isDir: ObjCBool = false
        let path = home + "/" + name
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        let hex = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let service = "Claude Code-credentials-" + hex.prefix(8)
        guard keychainHas(service) ?? true else { continue }
        let suffix = String(name.dropFirst(".claude-".count))
        let id = accountID(suffix: suffix, hash: hex)
        out.append(AcctCfg(id: id, label: suffix.uppercased(), keychain: service, dir: "~/" + name))
    }
    return out.isEmpty ? [defaultAcct] : out
}
let ACCOUNTS = discoverAccounts()
let USAGE_URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let BETA_HEADER = "oauth-2025-04-20"
let POLL_SEC: TimeInterval = 1800       // 定时节奏：每 tick 只拉一个账户，各账户轮流（每个账户 N×30 分钟一次）
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
// 实际生效的手动刷新间隔：一次强刷每个账户一个请求，账户多了就按账户数放大（每个 100 秒），
// 把手动刷新的总频率压在约 0.6 请求/分钟以内；三个账户时仍是 5 分钟（Codex 2026-10-14）
let FORCE_GAP: TimeInterval = max(FORCE_MIN_GAP, 100 * Double(max(ACCOUNTS.count, 1)))
let TICK_MIN_GAP: TimeInterval = 15     // 自动拉取去重间隔（定时器与菜单打开撞车时）
let ACCT_MIN_GAP: TimeInterval = 300    // 非强刷时单账户最小尝试间隔（防频繁开菜单放大请求）
let BACKOFF_MAX: TimeInterval = 3600    // 退避上限
let CRED_WATCH_SEC: TimeInterval = 60   // 凭据失效的账户：多久看一眼钥匙串条目有没有被 Claude Code 重写。
                                        // 只查属性不发请求，也只在有账户凭据失效时才起子进程
let CRED_ERRORS: Set<String> = ["token_expired", "no_token"]   // 跑一次 claude 就能好的那几类失败
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
let ROW_W: CGFloat = 530                 // 账户行宽度 = 菜单宽度（见 AccountRowView）；2026-10-14 加 5 小时列，+110
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

// 一次拉取的结果。之前是 (周, Fable, 错误码, Retry-After, 5 小时) 的元组，加套餐类型时改成具名字段：
// 六个位置靠 r.0…r.5 取，写错一位编译器也不会拦。
struct FetchResult {
    var weekly: Block? = nil
    var fable: Block? = nil
    var error: String? = nil        // nil = 成功
    var retryAfter: Double? = nil   // 429 时服务器给的 Retry-After 秒数
    var fiveHour: Block? = nil
    var plan: String? = nil         // 钥匙串凭据里的 subscriptionType，和这次拉取成败无关
    var credParsed = false          // 凭据 JSON 读成功了：此时 plan 为 nil 表示「凭据里就没这个字段」，可以清掉旧值
}

struct AcctSnap {
    var cfg: AcctCfg
    var active = false
    var error: String?       // 最近一次拉取的错误(nil=成功)；出错不清空旧数据，且跨重启保留
    var weekly: Block?       // 周限额(全模型)
    var fable: Block?        // Fable 周容量
    var plan: String?        // 套餐类型：钥匙串凭据里的 subscriptionType（"max" / "pro" …），决定画不画 Fable
    var fiveHour: Block?     // 5 小时窗口（只在下拉菜单行里显示；变化快，轮询又懒，数字可能旧，靠 tooltip 的数据年龄判断）
    var dataAt: Date?        // 数据成功拉到的时间（墙钟：要跨重启显示“数据多旧”）
    var attemptAt = MONO_PAST   // 上次尝试拉取（单调时钟，不论成败，调度按它轮转）
    var notBefore = MONO_PAST   // 该账户的退避闸门（单调时钟）
    var backoff: TimeInterval = 0
    var rateLimited = false  // 闸门是服务器给的(429) 还是我们自己加的软退避——决定手动刷新能否越过
    var parseFails = 0       // 连续解析失败次数；到 PARSE_GIVE_UP 就收下新形状，别把账户卡死
    var credFailAt: Double?  // 凭据类失败（CRED_ERRORS）那次读钥匙串之前的墙钟时刻；钥匙串条目在这之后被重写过，
                             // 就是 Claude Code 换了新 token，立刻重拉。非凭据类失败或成功时为 nil。墙钟是因为要跟 mdat 比
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
    private let credQ = DispatchQueue(label: "cred")     // 钥匙串修改时间检查（不排在 workQ 上：一次拉取最坏卡 60 秒）
    private var snaps: [AcctSnap]
    private var refreshing = false
    private var credChecking = false
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
            snaps[i].fiveHour = Block.from(e["five_hour"])
            snaps[i].plan = e["plan"] as? String
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
            if snaps[i].dataAt == nil { snaps[i].weekly = nil; snaps[i].fable = nil; snaps[i].fiveHour = nil }
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
            // 凭据失败时刻也跨重启保留，否则重启后要干等退避走完。旧版 state.json 没这个键，
            // 拿 attempt_at 顶上——它落盘时被夹到「最多 ACCT_MIN_GAP 前」，可能比真实失败时刻晚，
            // 晚了只是错过这一次快速重拉、退回退避节奏，不会多打请求
            if let err = snaps[i].error, CRED_ERRORS.contains(err),
               let cf = jsonNum(e["cred_fail_at"]) ?? jsonNum(e["attempt_at"]),
               cf.isFinite, abs(cf) < EPOCH_MAX {
                snaps[i].credFailAt = cf
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
            // 只算界面上真正显示得出来的数据：Pro 账户缓存里残留的 Fable 桶行里不显示，页脚也不能拿它报年龄
            u.oldestAge = snaps.filter(hasShownData).compactMap { $0.dataAt }.min().map { max(0, -$0.timeIntervalSinceNow) }
            u.missingData = snaps.contains { $0.dataAt == nil || !hasShownData($0) }
            // 退避情况：最快多久有账户能恢复，以及是不是全都被关着。
            // 只报“全部”是不够的——一个账户被关一小时、另一个健康时，页脚照样会理直气壮
            // 写“后台每 N 分钟轮询一次/账户”，那对被关着的那个来说是假话。
            let waits = snaps.map { max(0, $0.notBefore - mono) }
            if let soonest = waits.filter({ $0 > 0 }).min() {
                u.gated = soonest
                u.allGated = waits.allSatisfy { $0 > 0 }
            }
            // 手动刷新真正可用还要多久：三道闸门取最大（自身节流 / 全局冷却 / 全部账户
            // 都卡在服务器给的 429 窗口里）。菜单项据此置灰并写明时间，别让用户点了没反应。
            var wait = max(FORCE_GAP - (mono - lastForce), globalCooldown - mono)
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
                if mono - lastForce < FORCE_GAP { return }
                // 全局冷却也要认。刚有账户吃到 429，就说明这个端点（同一个 IP）正在
                // 拒人，此时去打另一个账户只是换个 token 撞同一堵墙。
                if mono < globalCooldown { return }
                // 服务器明确说了要等（429/Retry-After）就必须等——这是最容易被连点
                // 砸穿的一条路径；我们自己给 401/网络错误加的软退避则可以越过，
                // 否则用户跑完 `claude` 刷新了 token 也得干等一小时。
                // 按上次尝试从旧到新排：批次遇到 429 会中途停下，固定按 A、B、C 的顺序的话，一个持续 429 的
                // 账户每次都排第一、每次都把整批停掉，后面的账户永远轮不到（Codex 2026-10-14）
                targets = snaps.indices.filter { !(snaps[$0].rateLimited && mono < snaps[$0].notBefore) }
                    .sorted { snaps[$0].attemptAt < snaps[$1].attemptAt }
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
            // 只给第一个记「已尝试」；批里后面的账户在 doRefresh 里真去拉之前才记——批次可能中途因 429 停下，
            // 没拉的不能算尝试过（Codex 2026-10-14）
            if let first = targets.first { snaps[first].attemptAt = mono }
        }
        guard !targets.isEmpty else { return }
        onMainCommon { self.onUpdate?() }   // 立刻把“刷新中”反映到界面（菜单开着也要生效）
        workQ.async { self.doRefresh(targets, force: force) }
    }

    // token 过期的账户不靠软退避干等。退避最长 1 小时，而这类失败在用户跑一次 claude 之后就好了：
    // 2026-10-24 实测 B 闲置过夜后 token 过期，用户 21:23:55 点了立即刷新（还是旧 token，401，退避 1 小时），
    // 21:24:03 Claude Code 才刷新 token——菜单栏要到 22:24 之后才肯再试，中间一直挂着陈旧的数字。
    // 这里每轮只看钥匙串条目的修改时间：晚于失败那次读取，就是换了新 token，立刻重拉这几个账户。
    // 不碰服务器给的 429 窗口和全局冷却；mdat 是本机写的，比当前时刻还晚（时钟被往回调过）就不认，
    // 否则每轮都会判成「刚换过」，变成每分钟一个必定失败的请求。
    func checkCredChange() {
        var cands: [(idx: Int, service: String, failAt: Double)] = []
        stateQ.sync {
            if credChecking { return }
            for i in snaps.indices { if let t = snaps[i].credFailAt { cands.append((i, snaps[i].cfg.keychain, t)) } }
            if !cands.isEmpty { credChecking = true }
        }
        guard !cands.isEmpty else { return }
        credQ.async {
            let wall = Date().timeIntervalSince1970
            // mdat 只到秒：同一秒里的重写也按「之后」算，宁可多试一次。试完 credFailAt 换成新的读取时刻，
            // 下一轮就比不过了，不会循环
            let changed = cands.filter { c in
                guard let m = keychainMtime(c.service) else { return false }
                return m >= c.failAt.rounded(.down) && m <= wall + 5
            }
            var targets: [Int] = []
            self.stateQ.sync {
                self.credChecking = false
                let mono = monoNow()
                if self.refreshing || mono < self.globalCooldown { return }   // 下一轮再看，条件还在
                // 挑候选和读钥匙串之间状态可能变了（手动刷新刚拉成功、又失败了一次），只认还停在同一次失败上的
                targets = changed.filter { self.snaps[$0.idx].credFailAt == $0.failAt && !self.snaps[$0.idx].rateLimited }.map { $0.idx }
                guard let first = targets.first else { return }
                self.refreshing = true
                self.lastAttempt = mono
                self.snaps[first].attemptAt = mono
                // 和 attemptAt 一样，只认领第一个；后面的在 doRefresh 里真去拉之前才认领
                self.claimCredRetry(first)
            }
            guard !targets.isEmpty else { return }
            onMainCommon { self.onUpdate?() }
            self.workQ.async { self.doRefresh(targets, force: false, credRetry: true) }
        }
    }

    // 认领一次「钥匙串已重写」的重拉，调用方必须已在 stateQ 里。
    // 新凭据 = 新起点：软退避清零，再失败就从 5 分钟重新爬。credFailAt 挪到现在（拉之前会落盘）：
    // 拉到一半崩溃重启，不会拿着同一次重写再试——KeepAlive 崩溃循环下那就是每分钟一个请求。
    // 必须在真去拉的那一刻才认领：一批里前一个吃了 429、后面的被跳过时，它们的标记要原样留着，
    // 下一轮接着试；提前一起认领掉的话，它们只能等常规轮询（Codex 2026-10-24）
    private func claimCredRetry(_ i: Int) {
        snaps[i].backoff = 0
        snaps[i].notBefore = MONO_PAST
        snaps[i].credFailAt = Date().timeIntervalSince1970
    }

    private func doRefresh(_ idxs: [Int], force: Bool, credRetry: Bool = false) {
        // 串行，避免同瞬间双请求。每个账户一出结果就提交并回调，不憋到整批结束：
        // 单账户最坏 45s(钥匙串) + 15s(网络)，N 个账户就是 N 分钟界面纹丝不动。
        // refreshing 仍然覆盖整个循环，这是有意的——这段时间里进来的 tick 就该被吞掉，
        // 而不是叠上第二批请求；代价（吞掉一次菜单打开的补拉）由“刷新中…”明说出来。
        // attemptAt 已经在 tick 里记下了，但只记在内存里。先落一次盘再去拉：
        // 下面这段最坏能卡 60 秒（45s 钥匙串 + 15s 网络），崩在里面的话这次尝试就没了，
        // 重启回来又是一次不受节流的请求——崩溃循环下就是每分钟好几个。
        saveState()
        for (n, i) in idxs.enumerated() {
            if n > 0 {
                // 一批拉多个账户（强刷，或钥匙串检查一次接住了好几个）：每拉下一个之前先看全局冷却——前一个刚吃了 429，
                // 这个端点正在拒人，换个 token 也是撞同一堵墙，整批停下。不停才记 attemptAt（钥匙串重拉还要认领），
                // 并照上面的理由先落盘再拉
                var stop = false
                stateQ.sync {
                    let m = monoNow()
                    if m < globalCooldown { stop = true } else {
                        snaps[i].attemptAt = m
                        if credRetry { claimCredRetry(i) }
                    }
                }
                if stop { break }
                saveState()
            }
            // 在读钥匙串之前记：Claude Code 恰好在「读完旧 token」和「401 回来」之间换了新的，
            // 修改时间也一定晚于它，下一轮钥匙串检查就能接住，不会漏
            let readAt = Date().timeIntervalSince1970
            let r = Self.fetchAccount(ACCOUNTS[i])
            let mono = monoNow(), now = Date()
            stateQ.sync {
                // 套餐类型来自钥匙串，和这次拉取成败无关。凭据读成功了就照它更新——包括字段不见了时清空，
                // 否则缓存里一个旧的 pro 会永远压着，接口明明给了 Fable 也画不出来；读都没读成功（超时、
                // 没这条）才保留旧值（Codex 2026-10-14）
                if r.credParsed { snaps[i].plan = r.plan }
                var failure = r.error
                // “成功”也可能只是半份。上游合法地可以不给某个桶（这个账户本来就没有 Fable），
                // 但“本来有、这次整块不见了”是结构变了，不是账户变了——比如 scope.model 的
                // 名字改了、或者 seven_day/weekly_all 一起换了名。这个判断只能在这里做：
                // 只有这里同时看得见新响应和缓存。要拿 nil 盖掉一个已经有的好数字，一律拒收。
                // 例外：套餐明说不含 Fable（上面刚按凭据更新过 plan）。这时接口本来就不给 Fable 桶，
                // 缓存里那份是同一目录上一个号、或降级前的套餐留下的，丢掉才对。照样拒收的话，
                // 周限额会跟着冻在旧数字上，旧重置时间一过还会被画成满环 ✓——实际可能已经快用完了
                // （2026-10-23 实测：~/.claude-b 从 Max 号换登 Pro 号，菜单栏满环，实际周用量 94%）
                if failure == nil {
                    let losesWeekly = snaps[i].weekly?.pct != nil && r.weekly?.pct == nil
                    let losesFable = includesFable(snaps[i]) && snaps[i].fable?.pct != nil && r.fable?.pct == nil
                    if losesWeekly || losesFable { failure = "err_parse" }
                }
                // 保护缓存是为了扛住抖动和改名，不是为了把账户焊死。连着 PARSE_GIVE_UP 次
                // 都是这个形状，就说明上游是真变了：收下它，让界面回到能继续更新的状态
                // （否则一个 Fable 桶改名会把周限额也一起冻住，而周限额是无辜的）。
                // 但收之前必须确认新形状**至少还带着一个百分比**：一份什么都没有的响应
                // 永远不是"新常态"，它就是坏的。少了这个条件，这条"认命"通道就等于给
                // 缓存清空开了张延迟 2 小时的支票——正是这整套东西要防的那件事。
                if failure == "err_parse" && snaps[i].parseFails >= PARSE_GIVE_UP
                    && (r.weekly?.pct != nil || r.fable?.pct != nil) { failure = nil }
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
                        let ra: Double? = (r.retryAfter?.isFinite == true && r.retryAfter! > 0) ? max(r.retryAfter!, 60) : nil
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
                    snaps[i].credFailAt = CRED_ERRORS.contains(err) ? readAt : nil
                } else {
                    snaps[i].error = nil
                    snaps[i].backoff = 0
                    snaps[i].rateLimited = false
                    snaps[i].parseFails = 0
                    snaps[i].notBefore = MONO_PAST
                    snaps[i].credFailAt = nil
                    snaps[i].weekly = r.weekly
                    snaps[i].fable = r.fable
                    // 5 小时桶不参与上面的「丢了就拒收」：它几小时就翻一轮，旧数字本来就没多少参考价值，
                    // 为它冻住整个账户（连同周限额）不划算。这次没给就显示「—」。
                    snaps[i].fiveHour = r.fiveHour
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
                    "plan": j(s.plan),
                ]
                // 没有生效中的退避窗口就干脆不写这个键。写成“当前时刻”看着无害，但存盘到
                // 重启之间时钟要是被往回调，它就成了一个未来时刻，白白把健康账户关进闸门。
                // notBefore 是单调时钟，写盘时换算成墙钟绝对时刻。
                if s.notBefore > mono { e["not_before"] = wall + (s.notBefore - mono) }
                if let cf = s.credFailAt { e["cred_fail_at"] = cf }
                if let at = s.dataAt {
                    e["at"] = at.timeIntervalSince1970
                    e["weekly"] = j(s.weekly?.dict)
                    e["fable"] = j(s.fable?.dict)
                    e["five_hour"] = j(s.fiveHour?.dict)
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

    // 解析：以 limits 数组为准（weekly_all=周限额，weekly_scoped=Fable 桶，session=5 小时窗口），
    // 缺失时退回顶层的 seven_day / five_hour（2026-10-14 实测两处给的是同一个数）
    static func parseUsage(_ obj: [String: Any]) -> (Block?, Block?, Block?) {
        var weekly = Block.upstream(obj["seven_day"])
        var fiveHour = Block.upstream(obj["five_hour"])
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
                case "session":
                    if let b = Block.limit(l), b.pct != nil || fiveHour?.pct == nil { fiveHour = b }
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
        return (weekly, fable, fiveHour)
    }

    static func fetchAccount(_ cfg: AcctCfg) -> FetchResult {
        let (token, kcErr, plan, credParsed) = readToken(cfg.keychain)
        guard let token = token else { return FetchResult(error: kcErr ?? "no_token", plan: plan, credParsed: credParsed) }
        var req = URLRequest(url: USAGE_URL)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(BETA_HEADER, forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-reset-widget/2.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        let out = Locked<FetchResult>(FetchResult(error: "err_timeout", plan: plan, credParsed: credParsed))
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil { out.set(FetchResult(error: "err_network", plan: plan, credParsed: credParsed)); return }
            guard let http = resp as? HTTPURLResponse else { out.set(FetchResult(error: "err_network", plan: plan, credParsed: credParsed)); return }
            if http.statusCode == 401 { out.set(FetchResult(error: "token_expired", plan: plan, credParsed: credParsed)); return }
            if http.statusCode == 429 {
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                out.set(FetchResult(error: "http_429", retryAfter: ra, plan: plan, credParsed: credParsed)); return
            }
            guard http.statusCode == 200 else {
                out.set(FetchResult(error: "http_\(http.statusCode)", plan: plan, credParsed: credParsed)); return
            }
            // 200 但正文不是预期 JSON，和状态码错误不是一回事，单独报
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                out.set(FetchResult(error: "err_body", plan: plan, credParsed: credParsed)); return
            }
            let (w, f, h) = parseUsage(obj)
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
            if w?.pct == nil && f?.pct == nil { out.set(FetchResult(weekly: w, fable: f, error: "err_parse", fiveHour: h, plan: plan, credParsed: credParsed)); return }
            out.set(FetchResult(weekly: w, fable: f, fiveHour: h, plan: plan, credParsed: credParsed))
        }
        task.resume()
        // timeoutInterval 是空闲超时；这里兜一个总时长上限，超了就取消任务（不留孤儿请求）。
        // 直接返回 err_timeout，不读 out：cancel 会让回调抢着写入 err_network，
        // 同一次超时报出来的错误码会飘。
        if sem.wait(timeout: .now() + NET_WAIT) == .timedOut {
            task.cancel()
            return FetchResult(error: "err_timeout", plan: plan, credParsed: credParsed)
        }
        return out.get()
    }

    // 返回 (token, 错误码, 套餐类型, 凭据 JSON 是否读成功)。失败原因必须分开报：超时 / 拒绝授权 / 没这一项 / JSON 变了
    // 全部塞进 "no_token"，用户就会拿着 `security dump-keychain` 去找一条明明存在的凭据。
    static func readToken(_ service: String) -> (String?, String?, String?, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return (nil, "kc_spawn", nil, false) }
        // 45s：给钥匙串授权弹窗留出人手点击的时间（5s 会把弹窗杀掉，用户永远来不及授权）
        if sem.wait(timeout: .now() + KEYCHAIN_WAIT) == .timedOut {
            p.terminate()
            try? pipe.fileHandleForReading.close()   // 不然每超时一次漏一个读端 fd
            return (nil, "kc_timeout", nil, false)
        }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            // 44 = errSecItemNotFound，真的没有这条；其余是权限/钥匙串本身的问题
            return (nil, p.terminationStatus == 44 ? "no_token" : "kc_exit_\(p.terminationStatus)", nil, false)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return (nil, "kc_bad_json", nil, false)
        }
        let oauth = obj["claudeAiOauth"] as? [String: Any] ?? obj
        // 套餐类型（"max" / "pro" …）和 token 在同一份凭据里，顺手带出来，不多发一个请求
        let plan = oauth["subscriptionType"] as? String
        guard let t = oauth["accessToken"] as? String, !t.isEmpty else { return (nil, "kc_no_field", plan, true) }
        return (t, nil, plan, true)
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
// 套餐含不含 Fable 周额度。以钥匙串凭据里的套餐类型为准：Max 含（每周最多一半额度可用在 Fable 上）；
// Pro 不含（Fable 走按量付费，不进套餐额度，接口也就不给 Fable 桶）——见官方帮助页
// "Claude Fable models on your plan"。读不到套餐类型或是别的类型（Team / Enterprise 按席位而定）时
// 退回看数据：拉到了周数据却没有 Fable 桶 = 不含；一点数据都没有时当作含（那是「还不知道」）。
func includesFable(_ s: AcctSnap) -> Bool {
    switch s.plan {
    case "pro"?: return false
    case "max"?: return true
    default: return s.fable != nil || s.weekly == nil
    }
}

// 套餐不含 Fable 时只看周：缓存里可能还留着降级前的 Fable 桶（缺桶保护会先保住它），它的重置时间
// 不能出现在只画周环的账户旁边（Codex 2026-10-14）
func resetEpoch(_ s: AcctSnap) -> Double? {
    includesFable(s) ? (s.fable?.resetsEpoch ?? s.weekly?.resetsEpoch) : s.weekly?.resetsEpoch
}

// 界面上算「有数据」：同理，不含 Fable 的账户不拿一个隐藏的 Fable 桶充数
func hasShownData(_ s: AcctSnap) -> Bool { s.weekly != nil || (includesFable(s) && s.fable != nil) }

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
// showInner=false 只画外环：给套餐里根本没有 Fable 的账户用（Pro：Fable 走按量付费、不进额度，
// 接口压根不给 weekly_scoped 桶）。和「有 Fable 但这次没数据」区分开——后者照画内环的淡轨道。
func ringImage(outerRem: Double?, innerRem: Double?, showInner: Bool = true, size: CGFloat = 15) -> NSImage {
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
        if showInner { ring(outerR - lw - 1, innerRem) }   // 内环：Fable（留 1pt 缝隙防糊成一团）
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

    // 账户名最宽 26pt：名字从 x=27 起、数据列从 66 起，中间还要给 ⚠ 留位。~/.claude-personal 这种
    // 长后缀截成「P…」，全名和目录在 tooltip 第一行（Codex 2026-10-14）
    private func fitLabel(_ full: String, _ color: NSColor) -> NSAttributedString {
        var a = seg(full, color, 13, bold: true)
        var n = full.count
        while a.size().width > 26 && n > 1 {
            n -= 1
            a = seg(String(full.prefix(n)) + "…", color, 13, bold: true)
        }
        return a
    }

    private func refreshTip() {
        var tip = "账户 \(snap.cfg.label)（\(snap.cfg.dir)）"
        if let ep = resetEpoch(snap) { tip += (tip.isEmpty ? "" : "\n") + "重置时间 \(resetAt(ep))" }
        if let p = snap.plan {
            let name = ["max": "Max", "pro": "Pro"][p] ?? p
            tip += (tip.isEmpty ? "" : "\n") + "套餐 \(name)" + (includesFable(snap) ? "" : "（Fable 不含在额度里）")
        }
        if let ep = snap.fiveHour?.resetsEpoch {
            tip += (tip.isEmpty ? "" : "\n") + "5 小时窗口 \(resetAt(ep)) 重置"
        }
        if let at = snap.dataAt {
            tip += (tip.isEmpty ? "" : "\n") + "数据更新于 \(ageText(max(0, -at.timeIntervalSinceNow)))"
        }
        if let e = snap.error {
            let has = hasShownData(snap)
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
        let lx = put(fitLabel(snap.cfg.label, on ? .labelColor : .secondaryLabelColor), 27, 4.5)

        let hasData = hasShownData(snap)
        // 账户级状态标记跟着账户字母走，不混进数据列
        if snap.error != nil && hasData { put(seg("⚠", .systemOrange, 9), lx + 3, 7.5) }
        guard hasData else {
            put(seg(snap.error.map { errText($0, hasData: false) } ?? "暂无数据", .systemRed, 12), 66, 5.5)
            return
        }

        // 三列数字：标签固定 x，数字右对齐固定右缘（跨行对齐）；颜色即严重度
        func gauge(_ name: String, _ b: Block?, _ labelX: CGFloat, _ numRight: CGFloat) {
            put(seg(name, .secondaryLabelColor, 11), labelX, 7)
            guard let rem = effectiveRem(b) else { putRight(seg("—", .secondaryLabelColor, 12), numRight, 6); return }
            putRight(seg("剩\(Int(rem))%", remColor(rem), 13, bold: true, mono: true), numRight, 4.5)
        }
        gauge("5小时", snap.fiveHour, 66, 156)
        if includesFable(snap) {
            gauge("Fable", snap.fable, 176, 266)
        } else {   // 套餐不含 Fable：写明「不含」，别用「—」让人以为是没拉到
            put(seg("Fable", .secondaryLabelColor, 11), 176, 7)
            putRight(seg("不含", .secondaryLabelColor, 12), 266, 6)
        }
        gauge("周", snap.weekly, 286, 358)

        // 右缘：距重置倒计时（Fable / 周的，不是 5 小时的）。常见最长 "20时47分后重置" 实测 94px
        // （起点 422）；能构造出来的最长是重置时刻贴着 EPOCH_MAX 的 "364583天8时后重置"，117px、
        // 起点 399。两种都离周列的右缘(358)有 ≥41px，撞不上（加 5 小时列时整体右移 110、行宽同步 +110）。
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
        // 启动预热：首次拉取之后再错峰拉两个账户（45 秒、105 秒，tick 自动挑最久没拉的），不和首次拉取
        // 挤在同一瞬间。封顶两个：usage 接口持续每分钟一次就会 429，账户一多按账户数展开就是一长串
        // 一分钟一个的请求（Codex 2026-10-14）。其余账户跟着每 30 分钟的轮转，打开菜单时数据旧了也会补拉。
        for k in 1..<min(max(ACCOUNTS.count, 1), 3) {
            every(45 + 60 * Double(k - 1), repeats: false, 5) { [weak self] in self?.store.tick() }
        }
        every(POLL_SEC, 10) { [weak self] in self?.store.tick() }
        // 界面时钟和网络节奏彻底分开：倒计时、"✓"、环的满格都是随时间自己在变的，
        // 挂在 30 分钟的拉取定时器上，就会出现额度早已恢复而菜单栏还挂着 "15m" 的半小时空窗。
        every(RENDER_SEC, 5) { [weak self] in self?.render() }
        every(CRED_WATCH_SEC, 10) { [weak self] in self?.store.checkCredChange() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        store.tick(staleGate: MENU_STALE_SEC)
        // 刚跑完 claude 就来看菜单的，不必等下一轮钥匙串检查（tick 正在拉别的账户时这次会让给下一轮）
        store.checkCredChange()
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
    // 从左到右按 ACCOUNTS 的顺序（A、B、C…），靠位置区分
    func render() {
        let u = store.uiState()
        let snaps = u.snaps
        let title = NSMutableAttributedString()
        for (i, s) in snaps.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ")) }
            let remW = effectiveRem(s.weekly)
            let remF = effectiveRem(s.fable)
            let att = NSTextAttachment()
            // 套餐不含 Fable（Pro）只画外环，判断见 includesFable
            att.image = ringImage(outerRem: remW, innerRem: remF, showInner: includesFable(s))
            att.bounds = CGRect(x: 0, y: -3, width: 15, height: 15)
            title.append(NSAttributedString(attachment: att))
            // 倒计时仍以 Fable 桶为准（该桶没给时间才退回周），文字和取值同源
            // 标题不放警标：闲置账户 token 过期是常态（数据照样够准），错误详情在菜单行/tooltip
            if (includesFable(s) ? (remF ?? remW) : remW) != nil {
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

    // 每个账户多久被后台轮到一次：每 tick 只拉一个账户、各账户轮流，所以是 账户数 × POLL_SEC
    func pollEveryText() -> String {
        let m = Int(POLL_SEC) * max(ACCOUNTS.count, 1) / 60
        if m % 60 == 0 { return m == 60 ? "每小时" : "每 \(m / 60) 小时" }
        return "每 \(m) 分钟"
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
            ?? "后台\(pollEveryText())轮询一次/账户"
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
