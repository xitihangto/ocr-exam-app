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

一个 macOS 本地 App。用户把**整份试卷**（最多 48 张图片，或 1 个 PDF）连同内置的《试卷识别规则.md》
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
  48 张 3MB 的照片 ≈ 1400 次 JS 调用，实测未做过
- DeepSeek 单条消息的附件数量上限未知，48 张可能被拒（代码会报「这些文件没能放进对话框」）

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
| 截图量尺寸截到全黑 | 亮度 0、找不到边框 | App 里那个**隐形 WKWebView 窗口**也是 layer 0 且 >400×400，会先被 `CGWindowListCopyWindowInfo` 匹配到；取「宽度最接近主窗口 620pt」的那个，不是第一个 |

**本工程新增的一条**：`AppState` 里删 `syncLegacyURL` 时，容易连带删掉紧邻的
`pasteFromClipboard`（整块替换的边界没算准）—— 编译报 "has no dynamic member"，先查这个函数还在不在。

### 界面尺寸 / 几何的两个工具

`tools/measure_gap.swift`：`swift tools/measure_gap.swift` 自动找主窗口 →
`screencapture -x -o -l<id>` → 沿中心列/1-4 列自下而上扫亮度，找卡片下边缘，换算成 pt。
只在需要**精确对齐**（如"底部间距缩到 0.4 倍"）时用，用完就停 ——
它只量数字，不看外观，和第 7 条铁律不冲突。

`tools/tile_geometry_test.swift`：**完全离屏**（`ImageRenderer`），不截图。
量两件事：① 546pt 宽画布上一行有几个预览格子、各多宽（横向大图不许把格子撑爆）；
② 两行网格的理想高度是否**正好**等于预览区可视高度（不等就会滚 1–2px、切掉最下面那排虚线）。

上传卡的当前常量（改高度后跑这两个工具复测）：
- `tileHeight = 82`，`gridVPadding = 1` → `previewHeight = 82*2 + 8 + 1*2 = 174`
- 卡片左右内边距 **10**；格子右侧让位 `scrollBarGutter = 13` → 格子宽 543（6 栏）
- 行数：12 个以内恒 2 行；超过按 `ceil(n/6)` 加行，上限 8 行（48 张）；3 行及以上才出滚动条
- 自绘滚动条：宽 **6**、`secondary.opacity(0.45)`、距右边 1pt，**overlay 不占布局**
- 页面底部留白 **12**（22 时内容 722.5 > 窗口 720，整页会滚 2px）
- 分隔线上下各 10pt；Word 卡底部到窗口底边 **19.5pt**（原 51.5pt 的 0.38 倍）
- 窗口标题栏：`titlebarSeparatorStyle = .none` + **界面自己画的 1px 常驻线**
  （`.line` 在这套「隐藏标题 + 透明标题栏」的窗口上不生效，只在 hover 时出现）

### 加一个文件到底做了什么（第 8 轮性能排查的结论）

用户 2026-10-29 问「10 个文件以上粘贴 / 上传 / 拖放为什么那么卡，难道已经 base64 切片了」。
**和 base64 无关**：分片（96000 字符灌 `window.__wbF`）只发生在「把附件传给 DeepSeek」那一步，
加文件时一次都不碰。卡的是下面三件事，现在都已改掉：

| 原来 | 现在 |
|---|---|
| `self.thumb = NSImage(contentsOf: url)` —— 整张原图当缩略图，4000×3000 一张约 48MB 位图，卡片只画 84pt | `CGImageSourceCreateThumbnailAtIndex` 降采样到 **360px**（`UploadItem.makeThumbnail`），单张 1–3ms |
| 判重把**整份文件**读进内存算 SHA-256 | `fingerprint(ofFileAt:)` 只读**头 128KB + 尾 128KB** + 字节数（小于 256KB 时头尾重叠＝全量，更准） |
| 一个文件一次 `uploads.append`，一次 @Published 变更就整张卡片重排一遍 | `acceptBatch` → 后台 `buildItems` 建好全部卡片 → `commitBatch` **整批只写一次** `uploads` |
| 剪贴板大图按原尺寸编码 PNG（10MB+，一两秒） | 长边先缩到 **2048**（`pasteMaxPixel`）再编码，缩略图从这张小 PNG 再降采样 |

两条新铁律：

1. **任何进 `uploads` 的批量操作，只能写一次** —— 循环里 `append` 就是 N 次全卡片重绘。
2. **预览卡片里永远不许放原图** —— `NSImage` 是懒解码，一旦被 `Image(nsImage:)` 画出来
   就按原始像素占内存；缩略图必须走 `makeThumbnail`。

量法：`--batchperftest` 造 12 张 2400×3200 JPEG，量「URL → 卡片」的总耗时。
当前实测 **86 ms / 12 张（7.2 ms 一张）**，而且这 86ms 已经在后台线程，主线程只做最后那一次合并。

自检里 `--pastetypetest` 需要同步读结果，所以有一个 `AppState.loadFilesOnMainThread` 开关
把建卡片拉回主线程；正式运行永远走后台，别把它默认改成 true。

---

## 8.1 上传通道实测（2026-10-29，推翻了一份外部调研）

背景：用户拿到一份《上传方案-技术调研.md》，结论是「base64 分片要 700 次 IPC、约 56 秒，
应该改用 `WKURLSchemeHandler` + `fetch`」。**这个结论是错的，实测推翻了它。**

实测（`--feedperftest`，12 个文件 × 2MB = 24MB）：

| 环节 | 耗时 |
| --- | --- |
| Swift base64 编码（3355 万字符） | 0.008 秒 |
| 分片 96000 注入（360 片） | 0.095 秒（每片 0.26 ms） |
| 分片 524288 注入（72 片） | 0.068 秒 |
| JS 侧 atob + `new File()`（12 个） | 0.065 秒 |
| **合计** | **0.07–0.1 秒** |

25 张 2MB 换算下来是 0.2 秒量级，和「56 秒」差 600 倍。**base64 分片不是瓶颈，不用换。**

外部通道三条全试过，都被 WebKit 堵死（真机实测，不是推测）：

| 通道 | 结果 |
| --- | --- |
| `fetch('wbfile:///…')` | `TypeError: Load failed`，**处理器一次都没进**（WebKit 直接拒非 http(s) 协议） |
| `XMLHttpRequest` | 同上 |
| `<script src="wbfile://…">` | 同上，脚本加载器也拒 |
| `<img src="wbfile://…">` | **能进处理器**（但 img 只负责显示，拿不到字节） |
| `fetch('http://127.0.0.1:8799/…')` | `Load failed`，本地服务端一条请求都没收到（https 页面被禁止直连本机 http） |
| 是不是 CSP 拦的 | 不是：`securitypolicyviolation` 无事件、无 meta CSP |

结论：**「让网页自己去拿本地文件」在这台机器上走不通**，别再往这个方向投入。

真正的耗时在 `waitFor` —— 等 DeepSeek 自己把文件传到它服务器、渲染出缩略图。
超时公式 `min(300, max(25, 20 + MB × 3))`，50MB 给 170 秒预算，每秒轮询一次。
那一段是网络 + 服务端，跟传输方式无关，换什么方案都省不掉。

---

## 8.2 点「继续」为什么会点空（2026-10-29 夜）

现象：AI 停下来、页面上明明有「继续生成」按钮，代码却点不中，第 3 次点完 12 秒没动静。

用户的实测事实（比代码推测可靠，以这个为准）：

- 手动点下去 **0.1–0.2 秒**就继续了，不是「等一会儿才反应」；
- 点完按钮**瞬间消失**，页面上**绝不会出现「停止」按钮**；
- 按钮出现和代码停止输出**几乎同时**。

两个已修的隐患：

1. **`scrollIntoView({behavior:'instant'})`** —— `instant` 不是标准值（标准只有 `auto` /
   `smooth`），WebKit 退回平滑滚动，于是紧接着 `getBoundingClientRect()` 拿到的是
   **滚动前的旧坐标**，点下去就落到别处。现在改成：按钮已在视口内就不滚；需要滚就返回
   `SCROLLING`，让 Swift 等 0.45 秒后重新取一次坐标。
2. **没有命中测试** —— 现在取到坐标后先 `document.elementFromPoint(cx, cy)`，命中元素必须
   是按钮本身或它的子孙，否则返回 `NOT_HIT:<标签:文字>`，绝不点击，等 0.5 秒重试。
   这同时防住「按钮正在淡出」「被浮层盖住」「坐标过期」三种情况。

**JS 点击依旧绝对不可用**（铁律第 1 条：页面校验 `event.isTrusted`），别回头去试。

---

## 9. 待办

- [ ] **解析残缺被误判成「本体残缺」**：2026-10-29 第一轮真实识别，卷子中间只是缺了两行
      解析，Word 里却插了「此处可能缺页」占位框。按规则应该是「解析可智能补全、本体不许猜」，
      说明 AI 把两者判反了。要拧的是提示词/规则的措辞，让它先判断「缺的是题目本体还是解析」。
      用户 2026-10-29 说这条先放一放，不是当前重点。
- [ ] **测试结束后把两个测试期开关一起关掉**：
      ① `AppState.autoOpenLogWhileTesting` 现在是 `true`（每次开跑自动展开运行日志，
      用户 2026-10-29 要求的「测试期放显眼处」）→ 改成 `false`，恢复成「只有点详情才出现」。
      ② `AppState.forceModesOffWhileTesting` 现在是 `true`（登录后强行关掉深度思考和智能搜索，
      用户 2026-10-29 要求「让它必须分段」以便反复验证点「继续」）→ 改成 `false`，
      恢复「强行开启」，和文章批改 / 讲义保持一致（开着时一次写完 101 秒，关掉要 125 秒）。
- [ ] **跑一轮真实识别**（登录 DeepSeek → 传 8–20 张真卷子 → 看 Word 出来什么样），这是唯一还没验证的主链路
- [ ] 摸清 DeepSeek 单条消息的附件数量上限，必要时把 48 张的上限调到实测值
- [ ] 大批量上传的耗时测量（20 张 / 48 张各一次），必要时把 `waitFor` 的超时公式再放宽。
      **注意区分两段**：①「加进预览框」已量过（`--batchperftest`，86ms/12 张，不卡）；
      ②「把附件喂给 DeepSeek」也已量过（`--feedperftest`，24MB 只用 0.1 秒，不卡）；
      真正没量的是 **③「等 DeepSeek 收下并渲染缩略图」**，见 §8.1
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
