# 试卷识别 App · 交接文档

> 最后更新：2026-10-29 ｜ 当前版本 **v1.0** ｜ 状态：**已发布，真实网页端跑通多轮；两条业务线（印刷试卷 / 学生手写作文）都已上线**
>
> 📌 **接手先看**：§1（这是什么）、§5（七条铁律，不许改；第 7 条是开发流程铁律）、§6（和两个前作的差异）、§7（两份规则 md 的分工）、§8（坑）、§9（待办）、§10（版本与发布）。
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

一个 macOS 本地 App。用户把**整份试卷**（最多 48 张图片，或 1 个 PDF）连同内置的**两份**规则
（《试卷识别规则.md》《学生手写文章转录规则.md》）上传到 DeepSeek 网页版，让 AI 先判断这批图是
**印刷体试卷**还是**学生手写作文**，再按对应那份规则生成一段 **Python 脚本**，App 用**自带的
Python 运行时**执行这段脚本，产出一份排版好的 docx。

全程不需要用户碰命令行，也不需要装任何东西。

---

## 1. 当前状态

### ✅ 已跑通（离线可验证）

- 编译：`./build.sh` 干净通过，产物 79MB（含 75MB Python 运行时）
- `--selftest`：包内**两份**规则 md、类型白名单（pdf/png/jpeg）、内置 Python 路径全部正确
- `--runpython tools/sample_build.py`：A4 + 2.2cm 页边距 + 宋体/TNR + 红答案 +
  **紫色插图占位表格（trHeight exact）** 全部能生成 —— 规则里的硬指标 python-docx 都做得到
- `--prompttest`：三种附件组合（1 PDF / 8 图 / 20 图）的提示词拼装正确，附件编号从 3 起、
  两份规则固定占 1 / 2，结束标记在
- 启动冒烟：App 能起来、不崩
- **真实网页端完整识别**：2026-10-29 已跑通多轮（11 页 300 DPI、13 页 150 DPI、
  虹口二模 10 页 150 DPI），上传 → 生成 → 自动接续 → 抓脚本 → 出 docx 全程无人工介入
- **「继续生成」自动接续**：同日累计点 6 次，0 次被吞（修复前是 5 次里 2 次被吞）

### ⚠️ 还没验证

- **情况 B（学生手写作文）没有真实跑过**：提示词和《学生手写文章转录规则.md》都定稿了，
  但到目前为止的真实识别全是印刷试卷（虹口二模等）。手写那条路只过了 `--prompttest`，
  AI 到底会不会按「数手写字符过半」判对、转录合辑长什么样，都还没人看过成品。
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

### ⚠️ 重启顺序：先 kill，再 build（别反过来）

`build.sh` 最后一行自己会 `open "/Applications/试卷识别.app"`。
如果按「build → kill → open」的老顺序，屏幕上会看到 app 被启动两次：

1. build 末尾那次 `open` —— **其实没生效**：旧进程还活着、同一个 bundle id，
   macOS 只是把旧窗口激活，不会启动新代码；
2. 然后 `kill` 掉旧进程，再 `open` —— 这一次才真正让新版本跑起来。

正确做法是**先把旧进程杀掉，再 build**，让 build 末尾那次 open 成为唯一一次干净启动：

```bash
OLD=$(pgrep -f "试卷识别.app/Contents/MacOS/ExamOCR" | head -1)
[ -n "$OLD" ] && kill -TERM $OLD; sleep 1
./build.sh --install          # 编译 + 安装 + 自己 open，一次到位
pgrep -fl "试卷识别"           # 确认只有一个进程
```

**另一个坑（2026-10-29 踩过）**：不要手动 `open dist/试卷识别.app`。
dist 和 /Applications 是两份同 bundle id 的包，各跑一个实例，会出现两个窗口。
要么只 open /Applications，要么让 build.sh 自己 open。

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
│   ├── 试卷识别规则.md          # 情况 A：印刷体试卷（附件 1）
│   ├── 学生手写文章转录规则.md   # 情况 B：学生手写作文（附件 2）
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
| 内置附件 | 规则 md + 模板 docx | 规则 md + 模板 docx | **两份规则 md**（试卷 / 手写转录），无模板 |
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
- 提示词：`AppState.promptText(paperNames:)`，按实际附件拼，**不写死文件名**；
  开头先让 AI「数手写字符」二选一（情况 A / 情况 B），再分别指「按附件 1」「按附件 2」
- 上传顺序：`Pipeline.pipeline()` 里 `uploads = [试卷规则, 手写规则] + 试卷各页`，
  `paperNames = uploads.dropFirst(2)` —— **固定两份规则打头，图片编号从 3 开始**
- 规则文件：`AppState.bundledRule` → `试卷识别规则.md`，
  `AppState.bundledHandwritingRule` → `学生手写文章转录规则.md`（缺任一份直接报「请重新安装」）
- `.md` 被拒收的兜底：`Pipeline` §4.1 **两份都逐个**改 `.txt` 重传，并同步替换提示词里的书名号文件名

---

## 7. 业务侧：两份规则 md

### 7.1 分工与「走哪条路」的判定（用户 2026-10-29 第 12 / 13 轮定）

同一个上传框既能放印刷试卷，也能放学生手写作文，所以规则从一份变两份，**两份都作为附件传上去**：

| 附件 | 文件 | 适用 |
| --- | --- | --- |
| 附件 1 | `试卷识别规则.md` | 情况 A：印刷体试卷 → 完整的 Word 试卷 |
| 附件 2 | `学生手写文章转录规则.md` | 情况 B：学生手写作文 → 学生手写文章转录（合辑） |

判定**不写在 md 里，写在提示词里**（`AppState.promptText`）：让 AI 先「数手写字符」——
一个英文字母算 1、一个中文字算 2，空格 / 空行 / 手机状态栏 / 软件界面栏都不算；
**手写占全图文字一半以上就一律走情况 B**，其余走情况 A。命中 B 就直接走，不再回头考虑 A。
一批里混着印刷试卷也不管：先数手写，过半就走 B，印刷部分当背景忽略。

设计上有个硬约束：**提示词只说规则 md 里没有的东西**（附件是哪几个、走哪条路、末尾「特别注意」、
`# ===EXAM-END===`）。排序依据、去重补全、去噪、保真、字体版式、页面设置全在 md 里，
提示词一个字都不重复 —— 两边都写同一件事，改一边就会打架（第 12 轮砍掉了 70% 的复述）。

### 7.2 试卷规则（附件 1）

`Resources/试卷识别规则.md` 是用户自己写的（原文件在 `~/Documents/deepseek_markdown_20261028_cb80f2.md`），
最初只改了一处：把「当前环境为 Python 3.15」改成 **3.12**（跟包内运行时对齐）。
之后按用户要求又收了几轮（填空 `___1___`、首行缩进 4 个半角空格、字号三档、深红 `#C00000`）。

规则里几条硬指标，代码侧都验证过能做到（见 `tools/sample_build.py`）：

- 页边距四边 2.2cm、装订线 0
- 中文宋体 / 英文 Times New Roman，红色答案还原为红色
- 插图占位：**1 行 1 列表格**，列宽 14cm、`trHeight exact` 7.5cm、紫字 `#800080`、单元格水平垂直居中
- 填空下划线、括号选项、表格结构必须保留
- **正文里的表格一律黑色单线边框**（2026-10-29 补）：原卷的对比表/课程表是带框线的，
  而 `python-docx` 默认建的表**没有边框**，模型不显式写 `tblBorders` 就会输出成三栏裸文字
- 大题之间空行，题目内部不空行

### 7.3 手写转录规则（附件 2）

整份 md 只讲手写作文，和试卷规则没有重叠。要点：

- **只录学生手写的英文正文**；成片的印刷题目、中文说明、答题卡边框、教师红笔批注一律不录
- 红笔的例外：**整篇都是红笔写的**才当正文（那是学生用红笔写的），零散红笔一律当批改
- 涂改以最终结果为准（修正液 / 划掉的都不录，旁边重写的录重写的）
- **照原样转录、不纠正拼写**，但只有真看清了才照抄；字母形状易混（`I/l`、`O/0`、`rn/m`）按通顺正确的拼写写
- 版式：Times New Roman 小四 12pt 不加粗、首行缩进 2 字符、**一篇一页**（篇间 `add_page_break()`）
- 左上角学生标识按**篇**统计（姓名 / 编号各 ≥50% 才加），小五 9pt 加粗，格式 `1-张三`
- 末尾「特别注意」是**可选**的：没有要提醒的就整段不写，连标题都不留

**两份 md 都只对 DeepSeek 说话**，不要在正文里加版本号或"本次修改了什么"。

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

### 8.2.1 第二次实测：第一次点击必被吞（2026-10-29 晚）

11 张讲义版、5 次点击，坐标全是 `REAL_MOUSE(1055,586)`，没有一次 `NOT_HIT`：

| 次序 | 结果 |
| --- | --- |
| 第 1 次 | 12 秒无内容 |
| 第 2 次 | 2 秒后涨 1173 字 |
| 第 3 次 | 12 秒无内容 |
| 第 4 次 | **12.0 秒**后涨 14477 字 |
| 第 5 次 | 8 秒后涨 3652 字 |

**每个「继续」按钮出现后的第一次点击都被吞，紧接着的第二次才有效。** 两条原因叠加：

1. `makeKeyAndOrderFront` 之后立刻 `sendEvent` —— 窗口还没真正成为 key，第一次点击被系统拿去激活窗口，事件落不到 webview；
2. 从没发过 `mouseMoved` —— 页面没有这个坐标的 hover 状态，React 的 `onMouseEnter` 不触发、WebKit 的 tracking area 也没建立。

对策：点击前先补一次 `mouseMoved`，等 0.12 秒，再 down/up。

判据同时换掉：原来用「12 秒内有没有涨字」，第 4 次**正好卡在 12.0 秒边界**才出字，
再慢半秒就会被判成无效、多点一次 —— 而多点会把生成掐死。
现在改成「点完 0.6 秒内按钮是否消失」（用户实测按钮瞬间消失），
消失后给 24 秒等出字，期间绝不重复点击。成功判定从 12 秒缩到 0.6 秒。

**验证结果（同日 07:44，13 张 150 DPI，2 次点击）：**

```
07:44:32 点「继续」第 1 次 → REAL_MOUSE(1055,586)
07:44:33 +0.2s 按钮已消失，点击被页面接受
07:44:35 +2.0s 继续生效（涨了 1170 字）

07:45:07 点「继续」第 2 次 → REAL_MOUSE(1055,586)
07:45:08 +0.2s 按钮已消失，点击被页面接受
07:45:10 +2.0s 继续生效（涨了 1138 字）
```

**2 次点击全部一次成功，0 次被吞**（上一轮是 5 次里 2 次被吞）。
确认按钮消失只用 0.2 秒（第一轮探测就命中），总耗时从 133 秒降到 100 秒 ——
省下的正是两次无效点击各自白等的 12 秒。

样本还小（2 次），以后再跑几轮继续观察。

---

### 8.2.2 第三次加固：probe 和 locate 判的不是同一个按钮（2026-10-29 上午）

上一轮只验证了「点得到」。这一轮通读代码时发现**点击和验证用的是两套不同的判据**。

#### 真 bug：两个函数找的不是同一个按钮

| | `locateContinue`（点谁） | `probeContinue`（点完还在不在） |
|---|---|---|
| 收集 | 全部候选 push 进数组 | 遍历时碰到第一个就 `return 'YES'` |
| 排序 | `ds-button` 优先 → `top` 降序 → 取最靠下（最新） | 无排序，按 DOM 顺序（通常最旧） |

后果：历史消息里若残留旧的「继续生成」按钮（DOM 没清掉），点完当前按钮后
`probeContinue` 依然能看到那个旧按钮 → 报「点了 0.6 秒按钮仍在，这次点击被吞了」
→ 攒够 2 次直接抛 `AI 停下来之后没有继续写。可能到了长度上限`。
**明明点成功了，却被判成失败。**

修法：`probeContinue(nearY:)` 只认**点击时的视口 y ±40px** 那个位置上的按钮。
`nearY` 从 `REAL_MOUSE(x,y)` 的返回值里解析；拿不到（走 JS 兜底点击）时
退化成「任意位置存在即算」，不会因此漏判。

#### 通用坑：`offsetParent === null` 判不出 `position: fixed`

`position: fixed` 元素的 `offsetParent` **同样是 null**，会被当成「不存在」。
本工程有 5 处用了这个判据：

| 位置 | 漏掉会怎样 |
|---|---|
| `probeComposer` | 漏掉「停止」按钮 → `generating` 恒 false → 以为没在生成、提前点继续 → **把生成掐死** |
| `locateContinue` / `probeContinue` | 吸附底部的按钮永远找不到 |
| `clickContinue`（JS 兜底） | 同上 |
| `sendNow` | 发不出去 |

全部换成 `getComputedStyle` 的 `display` + `getBoundingClientRect()` 实际宽高：
`display:none` 的元素 rect 全 0，祖先隐藏也全 0，能兜住；`visibility:hidden`
另外用 computedStyle 挡。**以后在这个工程里判按钮可见性，一律别用 `offsetParent`。**

#### 24 秒死等改成盯按钮

原来点完后 `for attempt in 0..<12` 干等 24 秒才回去检查。AI 有时只写两三百字又截断，
按钮几秒内就重新出现，这 24 秒纯白等。现在 6 秒后开始顺带探测按钮，一冒出来就 `break`
交回外层循环（外层还有 4 秒保护期兜着，不会乱点）。

#### 验证结果（同日 09:30，虹口二模 10 张 150 DPI）

```
09:30:32 +35.3s 点「继续」第 1 次 → REAL_MOUSE(1055,586)
09:30:33 + 0.2s 按钮已消失，点击被页面接受
09:30:35 + 2.0s 继续生效（约 2 秒后开始出字，涨了 973 字）
```

1 次点击、0 次被吞，58 秒出 docx（上一轮 100 秒）。

**⚠️ 但要说清楚：这轮只点了 1 次继续，旧按钮残留的场景没出现，
所以「只认 ±40px」这条新逻辑没被真正压到 —— 异常路径仍未验证。**
修它是因为逻辑上确实不一致，不是因为现场复现过。

---

## 8.3 DeepSeek 输入区开关的真实 DOM（2026-10-29 用户 DevTools 实测）

「深度思考」「智能搜索」两个开关是同一套设计系统组件，判据完全一致：

```html
<!-- 关 -->
<div tabindex="0" aria-pressed="false"
     class="f79352dc ds-toggle-button ds-toggle-button--m">
  <div class="ds-toggle-button__icon">…</div>
  <span class="_6dbc175">深度思考</span>
  <div class="ds-focus-ring">…</div>
</div>

<!-- 开：aria-pressed 变 true，class 多一个 ds-toggle-button--selected -->
<div tabindex="0" aria-pressed="true"
     class="f79352dc ds-toggle-button ds-toggle-button--m ds-toggle-button--selected">
  …
</div>
```

三条可用判据，优先级从高到低：

1. **`aria-pressed`**（`true` / `false`）—— 就在 `ds-toggle-button` 那个 div 自己身上，最稳；
2. **class 里有没有 `ds-toggle-button--selected`** —— 语义化命名（`ds-` 是 DeepSeek 自己的设计系统前缀），
   比 `f79352dc` 这种哈希类名稳定得多；
3. 颜色（偏蓝）—— 只在上面两条都失效时兜底。

两个坑：

- **不要用 `[class*="ds-toggle-button"]`**，那会连 `ds-toggle-button__icon`、
  `ds-toggle-button__label` 这些子元素一起选中。用 `.ds-toggle-button`，只匹配完整的类名 token。
- **关闭态的修饰符两边不一致**：智能搜索关着时似乎带 `--unselected`，深度思考关着时只有 `--m`。
  所以**不要拿 `--unselected` 当判据**，只认 `aria-pressed` 和 `--selected`。

代码在 `Scripts.probeComposer` 的 `findExact()`（精确路径）和 `findMode()`（模糊兜底）。
日志里 `deepVia` / `smartVia` 会写明走的哪条：`class` = 精确命中，`fuzzy` = 退回猜颜色，`none` = 没找到。

---

## 8.4 v1.0 正式版收尾（2026-10-29）

三件事，都是「把测试期的东西撤回正式状态」。

### 8.4.1 深度思考 + 智能搜索恢复强行开启

`AppState.forceModesOffWhileTesting` 从 `true` 改回 `false`。

测试期设 `true` 是为了把「点继续」逼出来 —— 关掉思考后单次输出上限变小，
一份卷子会切 4 段、点 4 次继续，分段逻辑才有机会被测到。代价是慢：
关掉时 125 秒，开着时 101 秒。正式版必须是 `false`，和文章批改 / 讲义保持一致。

### 8.4.2 运行日志不再落盘

删掉了 `AppState.logFileURL` 和 `log()` 里写文件那三行。

- **原来**：每写一行日志就把整篇重写一次 `~/Library/Logs/试卷识别/运行日志.log`
- **现在**：日志只在内存 `progressLines` 里，面板的「复制全部」照样能贴出来

用户 2026-10-29 定：正式版不在用户机器上留日志文件。
顺带 `autoOpenLogWhileTesting` 也改回 `false`，恢复成「只有点详情才出现」。

> 代价要说清楚：出问题又没开面板时，事后拿不到日志。要排查只能让用户重现一次。
> 如果哪天觉得这个代价不划算，把 `log()` 里那三行加回去即可。

### 8.4.3 版本 1.0

`CFBundleShortVersionString` = `1.0`，`CFBundleVersion` = `10`。
README 的版本行和 curl 下载链接同步到 v1.0。

---

## 8.5 线上事故：思考区里的草稿被当成最终答案执行（2026-10-29 14:29）

**现象**：用户传了 10 张微信图片，出来的 Word 是一份「2026-2027 学年复旦附中…英语卷」，
跟原图毫无关系。翻 DeepSeek 的思考过程才发现，AI 在推理里写了一段「我无法真实地看到图片…
我将模拟一份试卷」，然后**在思考区里就把整份 Python 草稿写完了，连 `# ===EXAM-END===` 都打上了**。

**证据**：`/tmp/试卷识别-run-1793255352/生成试卷.py` 与那段思考草稿逐字一致 —— 执行的确实是草稿。

**根因**：深度思考把推理过程也渲染成 markdown，**思考区里同样有 `.md-code-block pre`**。
`replyState` 取的是「页面上最后一个 pre」，`hasEndMark` 看的是「这个 pre 的末尾 300 字」——
草稿正好是最后一个，标记也在，于是「看到结束标记 → 等 3 秒 → 判定写完 → grabScript 抓走 → 执行」。
`grabScript` 也是全页收集代码块再挑最长的，同样会挑到草稿。

**修法三层**（都在 `Scripts.swift`）：

1. **思考区排除**：`_wbIsThinking(el)` 沿祖先链查 `class / data-testid / id`，
   命中 `think|reason` 就跳过。真名是 **`ds-think-content`**（从 App 自己的 WebKit 缓存
   `~/Library/Caches/com.workbuddy.examocr/WebKit/NetworkCache` 里查到的，出现 50 次，
   和 `ds-markdown` / `ds-button` 同一套语义化命名）。
   换类名时靠两条兜底：① `aria-expanded` 容器且标题文字含「思考」；② `getBoundingClientRect().height < 1`
   （折叠起来的思考区高度是 0）。
2. **抓取同步过滤**：`grabBlocksBuild` 用同一套判据，思考区的草稿一个都不进 `window.__wbCode`。
   顺手修了一个从作文版克隆过来没改干净的地方：剥结束标记那行写的是 `===ESSAY-END===`，
   本工程是 `===EXAM-END===`。
3. **兜底拦截**：`grabScript()` 执行前先读「回答区正文」（`Scripts.answerText`，同样排除思考区），
   一旦出现「看不到 / 无法查看 / 无法读取…图片」这类说法，**直接抛错不执行**。
   宁可让用户重跑，也不能把编出来的假试卷当成品交出去。
   正则只认明确指向图片的说法，不会误伤「第 3 页字迹看不清」这种正常的「特别注意」。

**验证**：`node --check` 三段注入 JS 语法；用模拟 DOM 跑了四组断言
（思考区草稿=true / 回答区代码=false / 换类名+aria 兜底=true / 正常解析里的「思考题」不误判）；
拦截正则对 3 条「AI 自曝看不到图」和 3 条正常文案做了正负样本。

**教训（下次写页面探测先问这一句）**：
凡是「取页面上最后一个 X」「全页收集 X」，先问一句 **这个 X 在思考区里会不会也有一份**。
深度思考把同一套 markdown 渲染器复用在了推理内容上，`.md-code-block`、`.ds-markdown` 都会出现两份。

---

## 9. 待办

- [ ] **修完必须再跑一轮真实识别（情况 A）**：这次改的是「判完成 / 抓代码」的判据，
      离线只能验语法和逻辑，真机上要看三件事：①日志里出现「思考区里也有 N 个代码块，已忽略」；
      ②出字过程中不再提前判定写完；③抓到的脚本长度和最终答案一致。
- [ ] **情况 B 还没真实跑过一轮**：提示词和手写规则 md 都定稿了，但真实识别全是印刷试卷。
      要找一批学生手写作文照片跑一遍，看三件事：①「数手写过半」判得对不对；
      ②一篇跨两页能不能正确拼合；③左上角学生标识的 ≥50% 统计是不是按篇算的。
- [ ] **规则里有一处歧义待用户拍板**：填空「固定 6 个下划线」和「忠于原图」可能打架 ——
      原图只画了 3 个下划线时，到底按 6 个还是按 3 个。要补一句谁优先，但得先由用户定。
- [x] **`.md` 被拒收的兜底覆盖两份规则**（2026-10-29）：原来只写死补传第一份，
      第二份会留在 missing 里照样抛错 —— 已改成两份逐个补传并同步替换提示词里的文件名。
- [ ] **解析残缺被误判成「本体残缺」**：2026-10-29 第一轮真实识别，卷子中间只是缺了两行
      解析，Word 里却插了「此处可能缺页」占位框。按规则应该是「解析可智能补全、本体不许猜」，
      说明 AI 把两者判反了。要拧的是提示词/规则的措辞，让它先判断「缺的是题目本体还是解析」。
      用户 2026-10-29 说这条先放一放，不是当前重点。
- [x] **两个测试期开关已在 v1.0 关掉**（2026-10-29）：
      `autoOpenLogWhileTesting = false`（恢复成「只有点详情才出现」）、
      `forceModesOffWhileTesting = false`（深度思考 + 智能搜索恢复强行开启，
      和文章批改 / 讲义保持一致）。
- [x] **跑一轮真实识别** —— 2026-10-29 已跑通多轮（11 页 300 DPI、13 页 150 DPI、
      虹口二模 10 页 150 DPI），上传 → 生成 → 自动接续 → 抓脚本 → 出 docx 全程无人工介入
- [ ] 摸清 DeepSeek 单条消息的附件数量上限，必要时把 48 张的上限调到实测值
- [ ] 大批量上传的耗时测量（20 张 / 48 张各一次），必要时把 `waitFor` 的超时公式再放宽。
      **注意区分两段**：①「加进预览框」已量过（`--batchperftest`，86ms/12 张，不卡）；
      ②「把附件喂给 DeepSeek」也已量过（`--feedperftest`，24MB 只用 0.1 秒，不卡）；
      真正没量的是 **③「等 DeepSeek 收下并渲染缩略图」**，见 §8.1
- [ ] 图标第一版是代码画的，用户看完可能要求改（改 `tools/make_icon.swift` 即可）
- [x] **GitHub 仓库已建**（2026-10-29）：<https://github.com/xitihangto/ocr-exam-app>，
      v0.1 / v0.2 / v1.0 三个 Release 都已出，CI 全绿

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
