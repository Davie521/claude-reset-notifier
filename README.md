# Claude Reset Notifier

macOS 菜单栏小组件：监控两个 Claude 账户的 **Fable 周容量**和**周限额**（剩余 % + 重置倒计时）。无后端、无依赖，一个 Swift 文件编译成单二进制。

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

## 工作方式

- 从 macOS 钥匙串**只读**取两个账户的 Claude Code OAuth token（绝不刷新，不会把 Claude Code 挤下线）
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

## 开发

```bash
swiftc -O -warnings-as-errors menubar/ClaudeReset.swift -o /tmp/crn -framework Cocoa   # 编译
shellcheck install.sh                                                                  # 脚本静态检查
```

CI（`.github/workflows/ci.yml`）在 PR 和 main 上跑的就是这两件事，macOS runner 编译、Linux runner 跑 shellcheck。

注意本机 shellcheck 可能比 runner 上的宽松（装 0.11.0 时踩过：本地全绿、CI 报 SC2015）。改完 `install.sh` 推之前用同源镜像复核一遍更省事：

```bash
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable install.sh
```

## 安装

两种方式**二选一**（同时跑会出现两个图标、把 usage 接口打限流，两个进程还会互相覆盖 `state.json` 里的退避窗口）。`install.sh` 检测到 Homebrew 版的 LaunchAgent（`homebrew.mxcl.claude-reset-notifier` 已注册或其 plist 还在）就拒绝安装，要强装用 `./install.sh --force`。

**方式一：Homebrew（私有 tap，适合装到其他机器）**

```bash
brew tap davie521/tap git@github.com:Davie521/homebrew-tap.git
brew install davie521/tap/claude-reset-notifier
brew services start davie521/tap/claude-reset-notifier   # 菜单栏常驻 + 登录自启
```

要求：机器有该 GitHub 账号的 SSH 权限（源码和 tap 都是私有仓库）、装了 Xcode Command Line Tools（用 swiftc 从源码编译）。

**方式二：install.sh（本机开发用）**

```bash
./install.sh
```

编译后装到 `~/Library/Application Support/claude-reset/` 并注册 LaunchAgent `com.yifan.claude-reset-menubar`（登录自启；内部标识沿用 claude-reset，改名不迁移运行时）。运行时文件不放仓库目录（Desktop 是 TCC 保护路径，launchd 后台进程在里面读写不稳）。

两种方式的状态文件都在 `~/Library/Application Support/claude-reset/state.json`。发新版：源码仓库打 tag 后，更新 [homebrew-tap](https://github.com/Davie521/homebrew-tap) 配方里的 `tag`/`revision`。

账户配置在 `menubar/ClaudeReset.swift` 顶部 `ACCOUNTS`；keychain service 名用 `security dump-keychain | grep 'Claude Code-credentials'` 查。当前在用账户的标记读 `~/.claude-current-acct`（内容 `a` 或 `b`）。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.yifan.claude-reset-menubar
rm ~/Library/LaunchAgents/com.yifan.claude-reset-menubar.plist
rm -rf ~/Library/Application\ Support/claude-reset
```
