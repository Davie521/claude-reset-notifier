# claude-reset

macOS 菜单栏小组件：监控两个 Claude 账户的**周限额**和 **Fable 周容量**（用量 % + 重置倒计时）。无后端、无依赖，一个 Swift 文件编译成单二进制。

信息密度优先，时间是主角。菜单栏标题每账户 = 一个余量圆环 + 距重置时间，如 `◔ 5d  ◑ 21h`：环形填充比例 = Fable 剩余量，环色 = 账户识别色（A 绿 / B 蓝），剩 ≤30% 变橙、≤10% 变红。点开后每账户一行（悬停可看重置时刻、数据年龄、错误详情）：

```
● A    Fable 剩97%   周 剩97%      6天0时后重置
● B    Fable 剩45%   周 剩64%    ⚠ 17时30分后重置
```

在用账户 = 实色点 + 全亮字；闲置账户 = 半透明点 + 灰字。

## 工作方式

- 从 macOS 钥匙串**只读**取两个账户的 Claude Code OAuth token（绝不刷新，不会把 Claude Code 挤下线）
- 背景轮询极懒：每 30 分钟调一次 `api.anthropic.com/api/oauth/usage`，且每次只拉一个账户、两账户轮流（单账户 1 小时一次）。这个接口限流极紧——实测持续每分钟 1 个请求都会 429，频率宁低勿高。体感不钝：打开菜单时数据超过 3 分钟旧会即时补拉一次，手动刷新也有节流
- 周限额取 `limits[]` 里 `kind=weekly_all`，Fable 取 `kind=weekly_scoped`（`scope.model.display_name=Fable`）
- 429 按账户独立退避：max(`Retry-After`, 5→10→20…分钟，上限 1 小时) + 60 秒全局冷却，一个账户被限流不影响另一个更新；失败期间继续显示上次数据（橙色降级），不清空
- 快照落盘 `state.json`，重启立刻有数据

## 安装

```bash
./install.sh
```

编译后装到 `~/Library/Application Support/claude-reset/` 并注册 LaunchAgent（登录自启）。运行时文件不放仓库目录（Desktop 是 TCC 保护路径，launchd 后台进程在里面读写不稳）。

账户配置在 `menubar/ClaudeReset.swift` 顶部 `ACCOUNTS`；keychain service 名用 `security dump-keychain | grep 'Claude Code-credentials'` 查。当前在用账户的标记读 `~/.claude-current-acct`（内容 `a` 或 `b`）。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.yifan.claude-reset-menubar
rm ~/Library/LaunchAgents/com.yifan.claude-reset-menubar.plist
rm -rf ~/Library/Application\ Support/claude-reset
```
