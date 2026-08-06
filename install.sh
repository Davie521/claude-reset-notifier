#!/bin/bash
# 编译并安装 claude-reset 菜单栏 App（LaunchAgent 常驻，登录自启）。
# 二进制 + state.json + 日志放 ~/Library/Application Support/claude-reset/，
# 不直接从仓库目录跑：Desktop 是 TCC 保护目录，launchd 后台进程在里面读写不稳。
# 用法: ./install.sh [--force]   --force 跳过 Homebrew 版共存检查
set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
if [ "$#" -gt 1 ]; then echo "参数过多：只接受一个可选的 --force" >&2; exit 2; fi
case "${1:-}" in
    "")        ;;
    --force)   FORCE=1 ;;
    *)         echo "未知参数: $1（只支持 --force）" >&2; exit 2 ;;
esac

# set -u 挡得住 HOME 没定义，挡不住 HOME=""——那样下面几个路径会指到 /Library/…
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "HOME 没设好: '${HOME:-}'" >&2; exit 2; }

UID_="$(id -u)"
LABEL="com.yifan.claude-reset-menubar"
BREW_LABEL="homebrew.mxcl.claude-reset-notifier"
RUNTIME="$HOME/Library/Application Support/claude-reset"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
BIN="$RUNTIME/claude-reset-menubar"

# 中途失败不留半成品（成功路径上这两个文件已经被 mv 走，rm -f 是空操作）
cleanup() { rm -f "$PLIST.new" "$BIN.new"; }
trap cleanup EXIT

# Homebrew 版和这一份互斥：同时跑会出现两个菜单栏图标、双倍请求把 usage 接口打限流，
# 而且两个进程都整体重写同一个 state.json，会互相抹掉对方的退避窗口——恰恰在最需要
# 退避的时候失效。bootout 只认自己的 label，认不出 brew 的，所以要显式查。
# 直接问这一个 label，而不是 grep 整份 `launchctl print gui/UID`：那份 dump 里还有一段
# disabled services，会留下早就不存在的服务名，grep 它会永久误报且用户无法解除。
if [ "$FORCE" -eq 0 ] \
   && { launchctl print "gui/$UID_/$BREW_LABEL" >/dev/null 2>&1 || [ -f "$AGENTS/$BREW_LABEL.plist" ]; }; then
    echo "检测到 Homebrew 版（$BREW_LABEL 已注册或正在运行）。" >&2
    echo "先跑 brew services stop davie521/tap/claude-reset-notifier，或用 ./install.sh --force 强装。" >&2
    exit 1
fi

# 顺序是这个脚本最要紧的地方：所有可能失败的事——建目录、编译、写 plist、把新文件挪到
# 最终位置——全部在碰正在跑的实例之前做完。任何一步失败都只是“旧的还在跑，新的没生效”，
# 而不是“旧的已卸载、新的没装上”。mv 是目录项替换，正在运行的旧进程仍持有旧 inode，
# 覆盖它是安全的。~/Library/LaunchAgents 在从没装过 LaunchAgent 的账户上并不存在，
# 不先建它，下面的 heredoc 会直接失败。
mkdir -p "$RUNTIME" "$AGENTS"
swiftc -O menubar/ClaudeReset.swift -o "$BIN.new" -framework Cocoa

# 路径要按 XML 转义再塞进 plist：$HOME 里有 & < > 时会写出一份坏 plist，
# bootstrap 只会给一句莫名其妙的报错
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
BIN_XML="$(xml_escape "$BIN")"
RUNTIME_XML="$(xml_escape "$RUNTIME")"

cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_XML</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$RUNTIME_XML/menubar.log</string>
    <key>StandardErrorPath</key>
    <string>$RUNTIME_XML/menubar.log</string>
</dict>
</plist>
EOF

# 两个 mv 都在 bootout 之前，所以无论哪个失败，正在跑的那个实例都没被碰过——
# 这才是“旧实例未动”的依据。磁盘上可能已经换了一半（先落地的那个），
# 但因为程序路径没变，重跑一次脚本就能收敛。
# -f 不能省：目标存在、当前用户不可写、且 stdin 是终端时（也就是人手敲 ./install.sh 的
# 常态），BSD mv 会弹 "override ...? (y/n)"，答 n 之后**返回 0 且什么都没做**——
# `||` 分支根本不触发，脚本会一路往下把旧实例 bootout 再按旧二进制拉起来，还打印“已启动”。
# -f 直接覆盖；真正动不了的目标（比如打了 uchg）它照样返回非 0，不会掩盖真失败。
mv -f "$BIN.new" "$BIN"     || { echo "写入 $BIN 失败，旧实例未动。" >&2; exit 1; }
mv -f "$PLIST.new" "$PLIST" || { echo "写入 $PLIST 失败，旧实例未动。" >&2; exit 1; }

# 到这里才动正在跑的实例。只用 bootstrap 换代，不用 kickstart 兜底：
# kickstart 只是重启 launchd 内存里那份定义，不会重新读 plist，而这个版本改过 plist 的键，
# 那样会“看起来成功了、其实还在跑旧定义”。
# bootout 的失败这里确实咽掉了，因为首次安装必然失败（没有这个服务）；真出问题的话，
# 下面的 bootstrap 会带着 launchd 自己的报错失败，不会被蒙混过去。
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
ok=0
err=""
for attempt in 1 2 3; do
    [ "$attempt" -eq 1 ] || sleep 1   # 刚 bootout 过之后偶发 error 5/37：旧实例还在收尾
    # 留住 launchd 自己的报错：这是唯一真的会让用户没有常驻进程的分支，
    # 丢掉 stderr 就只能靠猜
    if err="$(launchctl bootstrap "gui/$UID_" "$PLIST" 2>&1)"; then ok=1; break; fi
done
if [ "$ok" -eq 0 ]; then
    echo "bootstrap 失败：${err:-（launchd 没给信息）}" >&2
    echo "手动修: launchctl bootout gui/$UID_/$LABEL; launchctl bootstrap gui/$UID_ \"$PLIST\"" >&2
    exit 1
fi

# bootstrap 返回 0 只代表“定义收下了”，程序起不来（EX_CONFIG 之类）它照样返回 0，
# 所以成功的话要亲眼确认它真的在跑，别打一句自己没验证过的“已启动”。
# 轮询而不是死等一秒：刚编出来的二进制第一次跑要过 Gatekeeper/AMFI，慢的机器上
# 一秒不够，会把装成功的情况报成失败。
# 另外先收进变量再匹配，不走管道：`launchctl print | grep -q` 在 pipefail 下，
# grep 命中后提前关掉管道有可能把 launchctl 打成 SIGPIPE，同样会误报。
running=0
for _ in 1 2 3 4 5; do
    sleep 1
    state="$(launchctl print "gui/$UID_/$LABEL" 2>/dev/null || true)"
    case "$state" in *"state = running"*) running=1; break ;; esac
done
if [ "$running" -eq 1 ]; then
    echo "已安装并启动: $BIN"
else
    echo "已装好但没跑起来。看日志: $RUNTIME/menubar.log" >&2
    echo "状态: launchctl print gui/$UID_/$LABEL" >&2
    exit 1
fi
