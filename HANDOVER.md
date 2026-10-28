# 试卷识别 App · 交接文档

> 最后更新：2026-10-29 ｜ 当前版本 **v0.1** ｜ 状态：**工程已建、编译通过、离线链路自检通过；还没跑过真实网页端的一轮完整识别**
>
> 📌 **接手先看**：§1（这是什么）、§5（七条铁律，不许改；第 7 条是开发流程铁律）、§6（和两个前作的差异）、§8（坑）、§9（待办）、§10（版本与发布：只在本地，别推）。
>
> ⚠️ 本工程从 `/Users/linquin/article-correct-app`（高三英语作文批改 v0.21）**整体克隆**而来，
> 那一个又是从 `/Users/linquin/lecture-app`（讲义生成 v0.27）克隆的。三代同一套骨架：
> 界面、交互、可靠性机制完全一致，只换业务 —— 附件、提示词、文案、结束标记、产物版式。
> 凡本文没写的实现细节，一律以作文批改版 HANDOVER.md 为准（`article-correct-app/HANDOVER.md`）。
>
> 🔒 **文档边界**：本文只写**工程侧**（代码、构建、踩坑、铁律）。
> `Resources/试卷识别规则.md` 是**网页版内嵌规则**，会被上传给 DeepSeek 看，不是本文的一部分。
> 规则 md 正文里不写版本号、不写变更说明 —— 它只对 DeepSeek 说话。

---

## 0. 一句话说清这是什么

一个 macOS 本地 App。用户把**整份试卷**（最多 50 张图片，或 1 个 PDF）连同内置的《试卷识别规则.md》
上传到 DeepSeek 网页版，让 AI 按规则生成一段 **Python 脚本**，App 再用**自带的 Python 运行时**
执行这段脚本，产出一份排版好的试卷 docx。

全程不需要用户碰命令行，也不需要装任何东西。

---

## 1. 当前状态

### ✅ 已跑通（离线可验证）

- 编译：`./build.sh` 干净通过，产物 79MB（含 75MB Python 运行时）
- `--selftest`：包内规则 md、类型白名单（pdf/png/jpeg）、内置 Python 路径全部正确
- `--runpython tools/sample_build.py`：A4 + 2.2cm 页边距 + 宋体/TNR + 红答案 +
  **紫色插图占位表格（trHeight exact）** 全部能生成 —— 规则里的硬指标 python-docx 都做得到
- `--prompttest`：三种附件组合（1 PDF / 8 图 / 20 图）的提示词拼装正确，结束标记在
- 启动冒烟：App 能起来、不崩

### ⚠️ 还没验证

- **真实网页端的一轮完整识别**（要登录 DeepSeek、要有真卷子）
- 大批量（20 张以上）上传的耗时与稳定性：分片灌字节是 96000 字符/次，
  50 张 3MB 的照片 ≈ 1400 次 JS 调用，实测未做过
- DeepSeek 单条消息的附件数量上限未知，50 张可能被拒（代码会报「这些文件没能放进对话框」）

### ❌ 已知的边界

- AI 是否遵守 `# ===EXAM-END===` 无 100% 保证
- 「继续生成」靠文本匹配识别，DeepSeek 改文案会失效
- 识别质量取决于模型视觉能力，本工程只负责「把图送到模型面前 + 把脚本跑成 docx」

---

## 2. 构建与调试

```bash
cd ocr-exam-app
./build.sh              # 增量构建到 dist/试卷识别.app
./build.sh --clean      # 全量重建（会删整个包）
./build.sh --install    # 构建 + 覆盖安装到 /Applications + 启动
```

无 Xcode 工程，纯 `swiftc -O` 手工组装 bundle。自动化会话里必须带 `-disable-sandbox`，
否则 SwiftUI 的 `@State` 宏展不开（build.sh 里已自动判断）。

### 命令行自检

```bash
BIN="dist/试卷识别.app/Contents/MacOS/ExamOCR"

"$BIN" --selftest                                  # 包内资源 / 类型白名单 / Python 路径
"$BIN" --runpython tools/sample_build.py           # 完整跑一遍 docx 生成链路（不碰网页）
"$BIN" --prompttest                                # 打三种附件组合的提示词
"$BIN" --pastetest                                 # 剪贴板图片落盘
"$BIN" --keytest                                   # ⌘J 开新对话（会真发一句"你好"）
```

### 界面状态演示（只改状态，不碰网络）

`--uidemo`（生成中）/ `--uidemo2`（已出成品）/ `--uidemo3`（失败）/
`--uidemo7`（20 张图，网格撑满）/ `--uidemo8`（等待粘贴 + 超限提示）/ `--uidemo9`（大图预览）/
`--logdemo`（日志面板）/ `--preview <文件>`（直接打开某文件的预览）

### 图标

```bash
swift tools/make_icon.swift docs/icon/icon-master.png     # 1024 母版（纯 CoreGraphics 画）
bash  tools/make_icns.sh    docs/icon/icon-master.png Resources/AppIcon.icns
```

图标是**代码画的**，不是 AI 生图：紫色渐变 squircle + 白纸 + 题号/题干/选项框 + 紫色对勾。
改形状只改 `tools/make_icon.swift` 里的坐标常量，改色改三个渐变 stop 就行。

---

## 3. 目录结构

```
ocr-exam-app/
├── build.sh                    # 编译 → 拷资源 → 拷 Python → 写 plist → 签名
├── Sources/
│   ├── ExamApp.swift           # @main + ContentView + UploadCard + ProgressCard + WordCard + LogPanel
│   ├── AppState.swift          # 全局状态机（ObservableObject），单槽位、批量图片
│   ├── Pipeline.swift          # 主流程：开新对话 → 上传 → 发送 → 等待 → 抓取
│   ├── Scripts.swift           # 注入网页的 JS（全部写成单个表达式）
│   ├── BrowserController.swift # WKWebView + 隐形窗口 + 真实鼠标/键盘注入
│   ├── PythonRunner.swift      # 内置 Python 执行器（prelude 猴补丁记录产物）
│   ├── ScriptExtractor.swift   # 从回复里挑出 Python 代码块
│   └── SafariBridge.swift      # AppleScript 通道（备用，默认不用）
├── Resources/
│   ├── 试卷识别规则.md          # 给 DeepSeek 的作业规则（唯一内置附件）
│   ├── AppIcon.icns
│   └── zh-Hans.lproj/InfoPlist.strings   # 显示名读这里，不是 Info.plist
├── Runtime/python/             # CPython 3.12.15 + python-docx（75MB）
├── tools/                      # 图标生成、icns 打包、格式冒烟脚本
└── docs/icon/                  # 图标母版
```

---

## 4. 一次点击发生了什么

```
用户点「开始识别」
  │
  ├─ Pipeline.runPipeline()  ← 后台线程，全程 beginActivity 防 App Nap
  │   │
  │   ├─ 1. 开新对话       根地址就跳过；会话页按 ⌘J；按不动才重载根地址
  │   ├─ 2. 探针           确认 textarea 和 input[type=file] 在
  │   ├─ 3. 分片灌字节      base64 每片 96000 字符 → window.__wbF
  │   ├─ 4. commitFiles    atob → Uint8Array → DataTransfer → input.files
  │   ├─ 5. 轮询文件名     确认 N 个附件都渲染出来（超时按体积算，20–300 秒）
  │   │      └─ .md 被拒 → 改 .txt 重传，并同步替换提示词里的文件名
  │   ├─ 6. fillText       先清空再填，回读比对（网页会把文件名塞进输入框）
  │   ├─ 7. sendNow        倒序找发送按钮，退化到 Enter keydown
  │   └─ 8. waitForReply() 轮询直到判定写完（§5 第 4 条）
  │
  ├─ grabScript()  取所有 .md-code-block pre，回传后打分挑最像的一段
  │
  └─ 主线程：offerScript() → 直接跑（不弹预览）
       └─ PythonRunner.run()  临时目录里跑，猴补丁记录 save 路径
           → Word 卡「下载 Word 试卷」
```

---

## 5. 七条铁律（前六条继承自两代前作，第 7 条本工程新增，别改）

1. **「继续生成」只能用真实鼠标事件**。页面查 `event.isTrusted`，`element.click()` 恒为 false，
   页面毫无反应。走 `NSEvent.mouseEvent` + `window.sendEvent`，窗口必须 `makeKeyAndOrderFront`。
2. **隐藏浏览器用 `alphaValue = 0` + `ignoresMouseEvents`**，不要挪到屏幕外
   （会被判 hidden 节流，双屏还会漏出）。
3. **量长度只用 `textContent`**，`innerText` 依赖布局，页面隐藏时失真。
4. **「AI 写完了」四层判定**：`generating` → `hasContinue`（真鼠标点 + 12 秒验证）→
   **结束标记连续 2 轮**（最强信号）→ 语义兜底（末尾有 `.save(` 且代码块后 ≥3 行说明）。
   总上限 10 分钟，**绝不执行截断脚本**。提示词里「至少 3 行收尾说明」是第 3 层的结构性证据，删了判定就退化。
5. **按钮功能优先于外观**：任何 hover 叠层必须 `allowsHitTesting(false)`，否则按钮点不动。
6. **`checkNames` 是子串匹配**：重名附件会互相顶掉，所以 `dedupeNames` 必须保留；
   提示词里的文件名要用**去重之后**的名字，跟附件条一致。
7. **（本工程新增，用户 2026-10-29 定，优先级最高）不做人眼可验证的自检**：
   界面、图形、排版、配色、图标、Word 成品外观 —— **一律不截图、不连拍、不读图确认、不做像素比对**，
   改完直接交付，由用户自己看（用户原话：「参与人并非程序员，但是不瞎」）。
   人眼不方便参与的部分（编译、启动、Python 链路、逻辑、数据）由 agent 自行判断要不要验，且只验一次。

---

## 6. 和两个前作的差异（本次改了什么）

| 维度 | 讲义生成 v0.29 | 作文批改 v0.21 | **试卷识别 v0.1（本工程）** |
|---|---|---|---|
| 上传槽位 | 2 个（考卷/答案） | 2 个（题目/作文） | **1 个（试卷）** |
| 单框上限 | 1 个 docx | 题目 1、作文 3 | **图片 50 / PDF 1，不混放** |
| 文件类型 | docx | doc/docx/pdf/png/jpg | **pdf/png/jpg**（doc/docx 不收，已经有字不用 OCR） |
| 内置附件 | 规则 md + 模板 docx | 规则 md + 模板 docx | **只有规则 md**（无模板） |
| 结束标记 | `# ===LECTURE-END===` | `# ===ESSAY-END===` | `# ===EXAM-END===` |
| 上传框布局 | 三等分 3 格 | 三等分 3 格 | **加号在左、文案在右；预览两行、一行 6 个、超出滚动** |
| 粘贴多文件 | 拒绝 | 拒绝 | **逐个收下**（批量试卷常一次复制一堆图） |
| 主题色 | 蓝青绿 | 品红 | **紫罗兰（#7D3DED 强调 / #FBF9FE 底）** |
| 产物命名 | 讲义-时间 | 批改-时间 | **试卷-时间** |
| 临时目录 | 讲义生成-run- | 作文批改-run- | **试卷识别-run-** |

### 关键代码位置

- 槽位：`AppState.Slot` 只有 `.paper` 一个 case；`uploads: [Slot: [UploadItem]]` 仍是字典（改起来省事）
- 上限：`AppState.limits(for:)` → `(images: 50, docs: 1)`
- 网格：`UploadCard.previewArea` + `columnCount` / `gridColumns` / `tileHeight` / `previewHeight`
  （1–3 个文件按个数分栏、4 个起固定 6 栏；高度恒为两行，空框也是这么高，卡片不会忽高忽低）
- 提示词：`AppState.promptText(paperNames:)`，按实际附件拼，**不写死文件名**
- 上传顺序：`Pipeline.pipeline()` 里 `uploads = [规则] + 试卷各页`，`paperNames = uploads.dropFirst()`
- 规则文件：`AppState.bundledRule` → `试卷识别规则.md`

---

## 7. 业务侧：规则 md

`Resources/试卷识别规则.md` 是用户自己写的（原文件在 `~/Documents/deepseek_markdown_20261028_cb80f2.md`），
本次只改了一处：把「当前环境为 Python 3.15」改成 **3.12**（跟包内运行时对齐）。

规则里几条硬指标，代码侧都验证过能做到（见 `tools/sample_build.py`）：

- 页边距四边 2.2cm、装订线 0
- 中文宋体 / 英文 Times New Roman，红色答案还原为红色
- 插图占位：**1 行 1 列表格**，列宽 14cm、`trHeight exact` 7.5cm、紫字 `#800080`、单元格水平垂直居中
- 填空下划线、括号选项、表格结构必须保留
- 大题之间空行，题目内部不空行

**规则 md 只对 DeepSeek 说话**，不要在正文里加版本号或"本次修改了什么"。

---

## 8. 踩过的坑（继承自前两代，别重犯）

| 坑 | 症状 | 解法 |
|---|---|---|
| `pre > code` | 代码块数恒为 0 | DeepSeek 的 `<pre>` 里没有 `<code>`，用 `.md-code-block pre` |
| JS 点击「继续」 | 点了没反应 | 页面校验 `isTrusted`，必须 NSEvent 注入 |
| 点完只等 3 秒 | 「只点一次就停」 | 要等 12 秒才判有效 |
| `innerText` 量长度 | 页面隐藏时误判写完 | 换 `textContent` |
| 用「挪到屏幕外」藏窗口 | 双屏漏出、定时器被节流 | `alphaValue = 0` + `ignoresMouseEvents` |
| `withAnimation` 推渐变角度 | 边框不转 | 用 `TimelineView` 逐帧算 |
| 叉按钮嵌在大按钮里 | 点叉变成选文件 | `ZStack` 叠在上层 |
| hover 叠层挡点击 | 按钮点不动 | 叠层加 `allowsHitTesting(false)` |
| 稳定 10 秒就当写完 | 抓到截断脚本，Python 报 SyntaxError | 必须有收尾标志，否则等到 10 分钟上限 |
| 启动瞬间判「未登录」 | 明明登录了却闪登录按钮 | 探针加 `bodyLen` + `hasLoginButton` |
| Finder 里没图标 | 只有 Dock 有 | `SetFile -a B` 标 bundle |
| 显示名改 Info.plist 不生效 | 名字还是旧的 | 读的是 `zh-Hans.lproj/InfoPlist.strings` |

**本工程新增的一条**：`AppState` 里删 `syncLegacyURL` 时，容易连带删掉紧邻的
`pasteFromClipboard`（整块替换的边界没算准）—— 编译报 "has no dynamic member"，先查这个函数还在不在。

---

## 9. 待办

- [ ] **跑一轮真实识别**（登录 DeepSeek → 传 8–20 张真卷子 → 看 Word 出来什么样），这是唯一还没验证的主链路
- [ ] 摸清 DeepSeek 单条消息的附件数量上限，必要时把 50 张的上限调到实测值
- [ ] 大批量上传的耗时测量（20 张 / 50 张各一次），必要时把 `waitFor` 的超时公式再放宽
- [ ] 图标第一版是代码画的，用户看完可能要求改（改 `tools/make_icon.swift` 即可）
- [ ] 还没建 GitHub 仓库；`release.yml` 已按新名字改好，等用户下令推上去后，建库推 `v*` tag 就能出 Release

---

## 10. 版本与发布（用户 2026-10-29 定）

- **以 git 方式开发，但只在本地**。仓库已经 `git init`（分支 `main`），**没有 remote**。
- **初步成熟可用之前，一律不推 GitHub**，也不建远程仓库、不打 tag、不跑 CI。
- 只有用户**明确说「推」/「推到 gh」** 时才执行：`gh repo create` → `git remote add origin` → 推 `main` → 打 `v*` tag。
  **不要自作主张推、不要顺手推、不要在"顺便清理一下"的时候推。**
- 版本号：日常改动沿用当前版本号，用户说要发布时才升 `CFBundleShortVersionString` 并打 tag
  （CI 会校验包内版本与 tag 一致，不一致直接失败）。
- `.gitignore` 里排除：`dist/`、`*.app`、`.workbuddy-ai/`（agent 工作笔记，不推）。
  `Runtime/python/`（75MB）**是入库的** —— CI 靠它打包，跟前两代一致。

---

## 11. 一句话给接手的人

**骨架别动，业务全在 `Resources/试卷识别规则.md` 和 `AppState.promptText` 里。**
遇到判定问题，先看 `Pipeline.waitForReply` 的四层判定和 `Scripts.replyState` 的字段，
再看日志面板里的页面截图和流程日志 —— 不要凭印象猜 DeepSeek 的 DOM。
