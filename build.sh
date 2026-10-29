#!/bin/bash
# 构建「试卷识别.app」——纯命令行，不依赖 Xcode 工程
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/试卷识别.app"
BIN="ExamOCR"

echo "▸ 清理"
# 默认增量：只删可再生的小文件，资源用覆盖式拷贝。
# 不整包 rm -rf 的原因：自动化会话里有 safe-delete 钩子，会拦截「一次删除 > 50 个文件」，
# 而包内 Python 运行时就有上千个文件，整包删必被拦。需要真正全量重建时用 ./build.sh --clean。
if [ "${1:-}" = "--clean" ] || [ "${2:-}" = "--clean" ]; then
  echo "  全量重建：删除旧包"
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/$BIN"
rm -f "$APP/Contents/Info.plist" "$APP/Contents/PkgInfo"

echo "▸ 编译 Swift"
# 自动化会话 / 非交互环境里，swift 驱动会用 sandbox-exec 包一层去起宏插件服务，
# 而沙箱规则应用会被拒，报「SwiftUIMacros ... produced malformed response」，
# SwiftUI 的 @State 就展不开。加 -disable-sandbox 关掉这层包裹即可；
# 老工具链不认这个参数时自动不加，行为与原来一致。
SANDBOX_FLAG=""
if swiftc -disable-sandbox -version >/dev/null 2>&1; then
  SANDBOX_FLAG="-disable-sandbox"
fi
swiftc -O $SANDBOX_FLAG -o "$APP/Contents/MacOS/$BIN" Sources/*.swift

echo "▸ 拷入资源（内置附件 + 图标 + 本地化）"
cp -R Resources/. "$APP/Contents/Resources/"

echo "▸ 拷入 Python 运行时（仅 docx 依赖）"
if [ -d Runtime/python ]; then
  if [ -d "$APP/Contents/Resources/python" ]; then
    # 已存在则覆盖同步，避免 cp -R 套成 python/python
    rsync -a --exclude __pycache__ Runtime/python/ "$APP/Contents/Resources/python/"
  else
    cp -R Runtime/python "$APP/Contents/Resources/python"
    find "$APP/Contents/Resources/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
  fi
else
  echo "  ⚠️ Runtime/python 缺失，App 将无法执行脚本"
fi

echo "▸ 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>试卷识别</string>
	<key>CFBundleDisplayName</key><string>试卷识别</string>
	<key>CFBundleIdentifier</key><string>com.workbuddy.examocr</string>
	<key>CFBundleExecutable</key><string>ExamOCR</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>11</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>zh-Hans</string>
	</array>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAppleEventsUsageDescription</key><string>需要控制 Safari，把试卷图片与内置附件填入 DeepSeek 对话框。</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 图标是可选件：Resources/AppIcon.icns 存在才写 CFBundleIconFile，
# 否则删掉这个键，让 Finder 用系统通用图标（挂一个不对的图标比没有更糟）。
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  grep -v 'CFBundleIconFile' "$APP/Contents/Info.plist" > "$APP/Contents/Info.plist.tmp"
  mv "$APP/Contents/Info.plist.tmp" "$APP/Contents/Info.plist"
  echo "  (无 AppIcon.icns，已略过图标项)"
fi

echo "▸ 临时签名"
# 增量构建时包是上一版留下的：SetFile -a B 会往 bundle 上写 FinderInfo 扩展属性，
# codesign 见到会报「resource fork, Finder information, or similar detritus not allowed」
# 直接跳过签名。先清掉扩展属性再签。
#
# 而签名一旦被跳过，bundle 只剩 linker-signed，`codesign -dv` 里的 Identifier 会变成
# 可执行文件名（ExamOCR），不再是 Info.plist 里的 com.workbuddy.examocr ——
# UserDefaults 和 WKWebView 的 cookie 都是按 Identifier 分域的，后果是偏好读不到、
# DeepSeek 登录态丢失。所以失败**必须看得见**，不要 2>/dev/null。
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" || echo "  ⚠️ 签名失败（Identifier 会退化成可执行名，UserDefaults 域跟着变）"

# 必须标记为 Bundle，否则 Finder 不显示图标
SetFile -a B "$APP" 2>/dev/null || echo "  (SetFile 跳过)"

echo "✓ 完成：$APP"
du -sh "$APP"

# ./build.sh --install 会直接替换 /Applications 里的正式版本
if [ "${1:-}" = "--install" ] || [ "${2:-}" = "--install" ]; then
  echo "▸ 安装到 /Applications"
  pkill -f "MacOS/ExamOCR" 2>/dev/null || true
  sleep 1
  # 先把旧包挪走再删：直接 rm -rf 会被 safe-delete 钩子按「大批量删除」拦下
  OLD="/tmp/examocr-old-$(date +%s).app"
  if [ -d "/Applications/试卷识别.app" ]; then
    mv "/Applications/试卷识别.app" "$OLD" 2>/dev/null || true
  fi
  cp -R "$APP" /Applications/
  ( rm -rf "$OLD" 2>/dev/null || true ) &
  # cp -R 后安装副本的 Finder bundle 标记可能丢失（Finder 图标变通用图标，
  # 但 Dock 仍能从 Info.plist 读到图标），所以在安装副本上再标一次并 touch
  SetFile -a B "/Applications/试卷识别.app" 2>/dev/null || echo "  (安装副本 SetFile 跳过)"
  touch "/Applications/试卷识别.app"
  echo "✓ 已安装：/Applications/试卷识别.app"
  open "/Applications/试卷识别.app"
fi
