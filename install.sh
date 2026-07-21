#!/bin/bash
# 编译并安装 claude-reset 菜单栏 App（LaunchAgent 常驻，登录自启）。
# 二进制 + state.json + 日志放 ~/Library/Application Support/claude-reset/，
# 不直接从仓库目录跑：Desktop 是 TCC 保护目录，launchd 后台进程在里面读写不稳。
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.yifan.claude-reset-menubar"
RUNTIME="$HOME/Library/Application Support/claude-reset"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$RUNTIME"
swiftc -O menubar/ClaudeReset.swift -o "$RUNTIME/claude-reset-menubar.new" -framework Cocoa
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mv "$RUNTIME/claude-reset-menubar.new" "$RUNTIME/claude-reset-menubar"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RUNTIME/claude-reset-menubar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$RUNTIME/menubar.log</string>
    <key>StandardErrorPath</key>
    <string>$RUNTIME/menubar.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "已安装并启动: $RUNTIME/claude-reset-menubar"
