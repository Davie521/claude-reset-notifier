# Claude Reset Notifier

macOS 菜单栏小组件：监控两个 Claude 账户的 **Fable 周容量**和**周限额**（剩余 % + 重置倒计时）。无后端、无依赖，一个 Swift 文件编译成单二进制。

## 显示

信息密度优先，时间是主角。菜单栏标题每账户 = 一个余量同心双环 + 距重置时间，如 `◎ 5d  ◎ 21h`：

- **外环 = 周限额剩余，内环 = Fable 剩余**，填充比例即剩余量；环全程单色（随菜单栏深浅自动黑/白，壁纸染色下也清晰），不做橙/红警示——额度本来就是拿来用完的，剩得少是常态不是事故，环只当油量表
- 左边永远是账户 A、右边是 B
- 重置时刻一过按"额度已恢复"显示（环回满、时间处显示 ✓）

点开后每账户一行（悬停可看重置时刻、数据年龄、错误详情；出错时账户字母旁有小 ⚠，继续显示缓存数据）：

```
● A⚠   Fable 剩97%   周 剩97%     6天0时后重置
● B    Fable 剩45%   周 剩64%    20时47分后重置
```

在用账户 = 实色点 + 全亮字；闲置账户 = 半透明点 + 灰字。「退出」真正退出（LaunchAgent 只在崩溃时自动拉起，登录时自启）。

## 工作方式

- 从 macOS 钥匙串**只读**取两个账户的 Claude Code OAuth token（绝不刷新，不会把 Claude Code 挤下线）
- 背景轮询极懒：每 30 分钟调一次 `api.anthropic.com/api/oauth/usage`，且每次只拉一个账户、两账户轮流（单账户 1 小时一次）。这个接口限流极紧——实测持续每分钟 1 个请求都会 429，频率宁低勿高。体感不钝：打开菜单时数据超过 3 分钟旧会即时补拉一次，手动刷新也有节流
- 周限额取 `limits[]` 里 `kind=weekly_all`，Fable 取 `kind=weekly_scoped`（`scope.model.display_name=Fable`；名字匹配不上就留空，不拿别的模型的桶冒充）
- 调度按"上次尝试时间"轮转（不论成败），一个账户持续失败（如闲置账户 token 过期）不会饿死另一个账户的刷新；非强刷时单账户最小尝试间隔 5 分钟
- 429 按账户独立退避：max(`Retry-After`, 5→10→20…分钟，上限 1 小时) + 60 秒全局冷却，一个账户被限流不影响另一个更新；手动重试失败不加倍退避。失败期间继续显示上次数据，不清空（200 但结构异常也按失败处理）
- 快照连同退避窗口一起落盘 `state.json`，重启立刻有数据、也不会无视还在生效的 Retry-After

## 安装

两种方式**二选一**（同时跑会出现两个图标并把 usage 接口打限流）。

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
