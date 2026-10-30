import Foundation
import AppKit

/// 无人值守跑一轮，供回归测试用（省得每次手动选文件、点按钮）。
///
/// 三种触发方式，**首选第 1 种**：
///
///     1) 直接执行包内二进制 —— 参数一定传得到，退出码还能同步拿到：
///        "试卷识别.app/Contents/MacOS/ExamOCR" --autopilot 第1页.png 第2页.png … [--out 目录]
///
///     2) defaults write com.workbuddy.examocr autopilotPaper -string "/abs/第1页.png,/abs/第2页.png"
///        defaults write com.workbuddy.examocr autopilotOut   -string "/abs/输出目录"
///        open -a "试卷识别"
///
///     3) open -a "试卷识别" --args --autopilot 第1页.png 第2页.png [--out 目录]
///        —— **不推荐**：`open --args` 不保证能传进 `CommandLine.arguments`
///        （`--logdemo` 在 2026-10-30 踩过，作文批改 App 同日又踩了一次）。
///
/// 第 1 种要求 App 没在运行（`open -a` 会复用旧实例，改完代码必须 `killall ExamOCR`）。
/// 第 2 种是兜底，也是唯一能「双击图标就替跑」的方式。
///
/// 试卷槽只有**一个**（`Slot.paper`），里面要么放 1 个 PDF，要么放若干张图片（上限 48），
/// 不许混放 —— 这两条由 `AppState` 自己把关，替跑不绕过它，放不进去就退出码 3。
/// `--autopilot` 后面可以跟多个位置参数（到下一个 `--` 或结尾为止），也可以写成一个逗号串。
///
/// **替跑只取「含答案的那份」Word。** 成品出来之后界面会问「要不要顺便生成纯考卷」，
/// 替跑不点它（那份要用户确认才生成），所以 `plainDocx` 恒为 idle。
///
/// 跑完把成品和日志复制到输出目录，然后按结果退出：
/// 0 = 成功、1 = 生成失败、2 = 超时、3 = 文件放不进上传框 / 文件不存在、4 = 双绿灯未确认。
/// 用完记得 `defaults delete` 清掉，否则下次启动还会自动跑。
enum Autopilot {

    struct Config {
        var paper: [URL]
        var outDir: URL
    }

    /// 整轮最长等多久。整份试卷页数多时确实慢（50 张能到十几分钟），
    /// 所以这里给到 30 分钟，别拿几十张图去撞 8 分钟的超时。
    private static let deadline: TimeInterval = 1800

    /// 等「深度思考 + 联网搜索」两个绿灯最多多久（页面慢时实测要 8~10 秒）
    private static let modeWait: TimeInterval = 60

    /// 等文件真正落进上传框最多多久（读盘 + 建缩略图是后台做的，几十张图要给足时间）
    private static let slotWait: TimeInterval = 120

    // MARK: - 解析启动参数

    /// 一个位置参数可能是 `a.png`，也可能是 `a.png,b.png`
    private static func split(_ raw: String) -> [URL] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    static func configFromLaunch() -> Config? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autopilot") {
            // 从 `--autopilot` 后面一直收到下一个 `--` 开头的参数为止
            var paper: [URL] = []
            var out: URL?
            var j = i + 1
            while j < args.count {
                let a = args[j]
                if a == "--out", j + 1 < args.count {
                    out = URL(fileURLWithPath: args[j + 1])
                    j += 2
                    continue
                }
                if a.hasPrefix("--") { break }
                paper.append(contentsOf: split(a))
                j += 1
            }
            guard !paper.isEmpty else { return nil }
            return Config(paper: paper,
                          outDir: out ?? paper[0].deletingLastPathComponent())
        }

        let d = UserDefaults.standard
        guard let p = d.string(forKey: "autopilotPaper"), !p.isEmpty else { return nil }
        let paper = split(p)
        guard !paper.isEmpty else { return nil }
        let o = d.string(forKey: "autopilotOut") ?? (p as NSString).deletingLastPathComponent
        return Config(paper: paper, outDir: URL(fileURLWithPath: o))
    }

    // MARK: - 主流程

    static func start(state: AppState) {
        guard let cfg = configFromLaunch() else { return }
        try? FileManager.default.createDirectory(at: cfg.outDir, withIntermediateDirectories: true)
        mark(cfg, "进入 start，试卷=\(cfg.paper.map(\.lastPathComponent))")
        NSLog("[autopilot] 试卷=%@ 输出=%@",
              cfg.paper.map(\.lastPathComponent).joined(separator: ","),
              cfg.outDir.path)

        // 先查文件在不在。上传框**不查存在性**（它只按扩展名收卡片），
        // 不在这儿拦一道，就要等 pipeline 跑到一半才报「未能打开文件」，
        // 退出码还变成 1（生成失败），看不出其实是路径写错了。
        let missing = cfg.paper.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            let names = missing.map(\.lastPathComponent).joined(separator: "、")
            finish(state: state, cfg: cfg, code: 3, note: "文件不存在：\(names)")
            return
        }

        // 给内置浏览器 3 秒把页面拉起来，先把文件塞进槽位（跟模式无关，可以先做）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark(cfg, "3 秒到，开始填槽")
            state.acceptBatch(cfg.paper, for: .paper)
            awaitSlots(state: state, cfg: cfg, until: Date().addingTimeInterval(slotWait))
        }
    }

    /// `acceptBatch` 是异步的（读盘、建缩略图都在后台），调完不能立刻断言成功，
    /// 得回来轮询「框里真的有东西了吗」。几十张图时这一步尤其不能省，
    /// 否则会误判成「放不进上传框」。
    private static func awaitSlots(state: AppState, cfg: Config, until limit: Date) {
        let got = state.items(for: .paper).count
        if got > 0 {
            mark(cfg, "试卷已就位（\(got) 个），等双绿灯")
            awaitModes(state: state, cfg: cfg, until: Date().addingTimeInterval(modeWait))
            return
        }
        if Date() > limit {
            finish(state: state, cfg: cfg, code: 3, note: "试卷放不进上传框")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            awaitSlots(state: state, cfg: cfg, until: limit)
        }
    }

    /// 界面上的「生成」按钮不等双绿灯也能点（模式检测失败时按钮不该永久变灰），
    /// 但无人值守必须等 —— 模式没确认就开跑，识别出来的试卷可能没开深度思考。
    private static func awaitModes(state: AppState, cfg: Config, until limit: Date) {
        if state.modesReady {
            mark(cfg, "双绿灯已就绪，启动 pipeline")
            state.runPipeline()
            poll(state: state, cfg: cfg, until: Date().addingTimeInterval(deadline))
            return
        }
        if Date() > limit {
            finish(state: state, cfg: cfg, code: 4,
                   note: "深度思考 / 联网搜索 \(Int(modeWait)) 秒内未确认开启")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            awaitModes(state: state, cfg: cfg, until: limit)
        }
    }

    private static func poll(state: AppState, cfg: Config, until limit: Date) {
        switch state.docx {
        case .ready(let url):
            finish(state: state, cfg: cfg, code: 0, note: nil, produced: url)
        case .failed(let message):
            finish(state: state, cfg: cfg, code: 1, note: message)
        default:
            if Date() > limit {
                finish(state: state, cfg: cfg, code: 2, note: "超时")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    poll(state: state, cfg: cfg, until: limit)
                }
            }
        }
    }

    // MARK: - 收尾

    /// 命令行侧看不到 NSLog，把关键节点落成文件，方便判断卡在哪一步
    private static func mark(_ cfg: Config, _ note: String) {
        let url = cfg.outDir.appendingPathComponent("_trace.txt")
        let line = "\(Date())  \(note)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func finish(state: AppState, cfg: Config, code: Int32,
                               note: String?, produced: URL? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cfg.outDir, withIntermediateDirectories: true)

        if let src = produced {
            let dest = cfg.outDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: src, to: dest)
                NSLog("[autopilot] 成品=%@", dest.path)
                mark(cfg, "成品已复制：\(dest.lastPathComponent)")
            } catch {
                NSLog("[autopilot] 复制成品失败：%@", error.localizedDescription)
                mark(cfg, "复制成品失败：\(error.localizedDescription)")
            }
        }

        let logURL = cfg.outDir.appendingPathComponent("autopilot-日志.txt")
        try? state.logText.write(to: logURL, atomically: true, encoding: .utf8)

        if let note = note {
            NSLog("[autopilot] 结束：%@", note)
            mark(cfg, "结束（退出码 \(code)）：\(note)")
        } else {
            mark(cfg, "结束（退出码 0）：成功")
        }
        exit(code)
    }
}
