# Claude Reset Notifier

[![CI](https://github.com/Davie521/claude-reset-notifier/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-reset-notifier/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**[English](README.md)**

macOS 菜单栏小组件：监控两个 Claude 账户的 **Fable 周容量**和**周限额**（剩余 % + 重置倒计时）。无后端、无依赖，一个 Swift 文件编译成单二进制。

> 非官方项目，与 Anthropic 无关。读的是 Claude Code CLI 在用的 `/api/oauth/usage`——一个没有文档的内部接口，随时可能改或者消失。见[注意事项](#注意事项)。

## 显示

信息密度优先，时间是主角。菜单栏标题每账户 = 一个余量同心双环 + 距重置时间，形如 `◔ 5d  ◑ 21h`（环是自绘的图，这里只是示意，并不是这两个字符）：

- **外环 = 周限额剩余，内环 = Fable 剩余**，填充比例即剩余量；环全程单色（随菜单栏深浅自动黑/白，壁纸染色下也清晰），不做橙/红警示——额度本来就是拿来用完的，剩得少是常态不是事故，环只当油量表
- 左边永远是账户 A、右边是 B
- 重置时刻一过按"额度已恢复"显示（环回满、时间处显示 ✓）

点开后每账户一行（悬停可看重置时刻、数据年龄、错误详情；出错时账户字母旁有小 ⚠，继续显示缓存数据）：

```
● A⚠   Fable 剩97%   周 剩97%       6天后重置
● B    Fable 剩45%   周 剩64%    20时47分后重置
```

在用账户 = 实色点 + 全亮字；闲置账户 = 半透明点 + 灰字。「退出」真正退出（LaunchAgent 只在崩溃时自动拉起，登录时自启）。

> 界面文案目前只有中文，全部在 `menubar/ClaudeReset.swift` 一个文件里、没有做本地化。英文版欢迎 PR。

## 工作方式

- 从 macOS 钥匙串**只读**取两个账户的 Claude Code OAuth token（绝不刷新、不写回，不会把 Claude Code 挤下线）。除了 `api.anthropic.com`，不往任何地方发数据
- 背景轮询极懒：每 30 分钟调一次 `api.anthropic.com/api/oauth/usage`，每次只拉一个账户、两账户轮流（**单账户 1 小时一次**）。这个接口限流极紧——实测持续每分钟 1 个请求都会 429
- 周限额取 `limits[]` 里 `kind=weekly_all`，Fable 取 `kind=weekly_scoped`（`scope.model.display_name=Fable`；名字匹配不上就留空，不拿别的模型的桶冒充）
- 调度按"上次尝试时间"轮转（不论成败），一个账户持续失败（如闲置账户 token 过期）不会饿死另一个账户的刷新
- 三道闸门决定什么时候真发请求：单账户最小间隔 **5 分钟**；打开菜单时被选账户数据超过 **25 分钟**旧才顺带补拉；手动刷新 **5 分钟**一次
- 失败按账户独立退避 5→10→20…分钟（上限 1 小时），429 另取 `Retry-After` 的较大者并加 60 秒全局冷却。一个账户被限流不影响另一个
- 「立即刷新」尊重服务器给的 429 窗口和全局冷却（连点也砸不穿），只越过我们自己给本地错误加的软退避——跑完 `claude` 刷新了 token 就能立刻验证。被闸门挡住时菜单项直接置灰并写明还要等多久，不会点了没反应
- 拉取失败期间继续显示上次成功的数据、账户字母旁挂 ⚠，不清空
- 快照、退避窗口、最近一次错误、上次尝试时间一起落盘 `state.json`：重启立刻有数据，不会无视还在生效的 `Retry-After`，也不会把失败账户的陈旧数字装成刚拉到的

## 设计取舍

几条不显眼但改代码时容易踩掉的约束。每条在 `menubar/ClaudeReset.swift` 里都有对应的长注释写清了来龙去脉，这里只列结论。

- **空数据绝不覆盖缓存。** 判空落在界面真正显示的百分比上，不是只看桶在不在——一个「只剩 `resets_at` 的空壳桶」会当成功把准数字盖掉。字段改名、变成字符串、变成 JSON 布尔、本来有值的桶整块消失，都算失败（新装机器上没有 Fable 桶则是正常的）
- **但保护缓存不能把账户焊死。** 同一形状连续拒收 5 次（`PARSE_GIVE_UP`，配合退避阶梯约 2 小时）就认下新结构，**前提是它还带着至少一个百分比**——一份什么都没有的响应永远不是「新常态」。少了这个前提，这条通道等于给"清空缓存"开一张延迟两小时的支票
- **两条崩溃循环入口必须堵死。** 非有限数值在入口丢弃（`-1e400` 会被 `JSONSerialization` 静静解析成 `-inf`，正向的 `1e400` 反而抛错），外来秒数转 `Int` 前一律先夹住（Swift 的 `Int(Double)` 越界是 trap 不是溢出）。进程一 abort，`KeepAlive` 就会拉起来重读同一份数据再崩，用户只能手删 `state.json` 才脱身
- **所有请求闸门按单调时钟计时**，改系统时间不会把轮询永久锁死。唯一按墙钟算的是「数据多旧」（它要跨重启），时钟往回调时按"旧"处理，只会多拉不会静默跳过
- **界面时钟和主线程回调走 common runloop 模式。** 菜单跟踪期间主 runloop 跑的是 `NSEventTrackingRunLoopMode`，默认模式的 `Timer` 一次都不触发，而菜单开着恰恰是唯一需要就地更新的窗口
- **菜单只建一次、就地更新**，不从异步回调里 `removeAllItems`——那会把鼠标底下的 item 在按下和抬起之间换掉

## 配置

账户写死在 `menubar/ClaudeReset.swift` 顶部：

```swift
let ACCOUNTS = [
    AcctCfg(id: "a", label: "A", keychain: "Claude Code-credentials"),
    AcctCfg(id: "b", label: "B", keychain: "Claude Code-credentials-CHANGEME"),
]
```

`keychain` 是 Claude Code 存该账户 OAuth 凭据用的钥匙串 **service 名**。第一个账户是默认的 `Claude Code-credentials`；之后每多登一个账户会另存一条带哈希后缀的，**后缀因人因机而异，必须自己查**：

```bash
security dump-keychain | grep 'Claude Code-credentials'
```

填错不会崩：那一行显示「钥匙串里没有这条凭据」，另一个账户照常跑。改完重跑 `./install.sh` 生效。

- **只有一个账户**：把第二行删掉
- **三个及以上**：能跑（点的颜色循环用），但有两处要一起改——菜单栏每账户画一组环，横着排会很长；页脚那句「后台每小时轮询一次/账户」是按 2 账户 × `POLL_SEC`（30 分钟）算死的
- **哪个账户「在用」**读 `~/.claude-current-acct`（内容 `a` 或 `b`）。它只决定实色点还是半透明点；文件不存在按 `a` 算。切账户的脚本自己往里写
- 跟踪的 scoped 模型按 display name 含 "Fable" 匹配（`UsageStore.parseUsage`）。要盯别的模型的周桶，改这个字符串，顺手把界面上写死的 `"Fable"` 标签一起改

## 安装

```bash
./install.sh
```

要求：装了 Xcode Command Line Tools（用 `swiftc` 从源码编译）。不需要 Homebrew，没有运行时依赖。

编译后装到 `~/Library/Application Support/claude-reset/` 并注册 LaunchAgent `io.github.davie521.claude-reset-menubar`（登录自启，`KeepAlive` 只在崩溃时拉起）。运行时文件不放仓库目录：仓库多半落在 `~/Desktop`、`~/Documents` 这类 TCC 保护路径下，launchd 后台进程在里面读写不稳。状态文件在 `~/Library/Application Support/claude-reset/state.json`，日志是同目录的 `menubar.log`。

`install.sh` 最要紧的是顺序：所有可能失败的事——建目录、编译、写 plist、把新文件挪到最终位置——全部在碰正在跑的实例之前做完。任何一步失败都只是「旧的还在跑，新的没生效」，而不是「旧的已卸载、新的没装上」。

它还兜着两条历史路径：

- 开源前的 LaunchAgent label 是 `com.yifan.claude-reset-menubar`。老实例还注册着的话，`install.sh` 会先把它 bootout 并删掉 plist 再装新的——否则两个图标、双倍请求，两个进程还会整体重写同一个 `state.json`，互相抹掉退避窗口
- 以前有一条 Homebrew 私有 tap 的安装路径，已废弃（tap 已删除）。`install.sh` 里仍保留互斥检查：检测到 `homebrew.mxcl.claude-reset-notifier` 已注册或其 plist 还在就拒绝安装，理由同上。确认不用管它就 `./install.sh --force` 强装

## 卸载

```bash
launchctl bootout gui/$(id -u)/io.github.davie521.claude-reset-menubar
rm ~/Library/LaunchAgents/io.github.davie521.claude-reset-menubar.plist
rm -rf ~/Library/Application\ Support/claude-reset
```

装过改名之前的版本，再清一次老 label：

```bash
launchctl bootout gui/$(id -u)/com.yifan.claude-reset-menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.yifan.claude-reset-menubar.plist
```

不留别的东西：这个 App 只往自己那个 Application Support 目录里写，从不改钥匙串。

## 开发

```bash
swiftc -O -warnings-as-errors menubar/ClaudeReset.swift -o /tmp/crn -framework Cocoa   # 编译
bash -n install.sh && shellcheck install.sh                                            # 脚本语法 + 静态检查
```

CI（`.github/workflows/ci.yml`）在 PR 和 main 上跑的就是这些，macOS runner 编译、Linux runner 跑脚本检查。`-warnings-as-errors` 是有意的：这个文件靠大量注释承载不变量，多出来的警告通常意味着有人改动时碰掉了什么。

注意本机 shellcheck 可能比 runner 上的宽松（装 0.11.0 时踩过：本地全绿、CI 报 SC2015）。改完 `install.sh` 推之前用同源镜像复核一遍更省事：

```bash
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable install.sh
```

## 注意事项

- **`/api/oauth/usage` 是没有文档的内部接口**，随时可能改结构或者消失。解析器为此做了准备（保住缓存、挂 ⚠、连续 5 次同一形状后认下新结构），但接口真没了就是真没了
- **限流很紧**。fork 之后把轮询调快只会换来 429——「单账户一小时一个请求」这个节奏本身就是设计
- 首次读钥匙串可能弹授权框（程序最多等 45 秒让你点）。选「始终允许」省得反复弹
- 只支持 macOS（Apple 芯片和 Intel 都行）；不签名、不公证，因为是你自己编译的
- 程序从不刷新 token。过期时那一行会写明，跑一次 `claude` 刷新后点「立即刷新」即可

## License

[Apache-2.0](LICENSE)。可自由使用、修改、再分发（含商用）；相应地，许可证要求保留版权声明和 [NOTICE](NOTICE)，并在改动过的文件里显著注明「你改过它」。
