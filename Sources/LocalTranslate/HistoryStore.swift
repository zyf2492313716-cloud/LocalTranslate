import Foundation

/// 翻译历史的本地存储。
///
/// 落盘位置：`~/Library/Application Support/LocalTranslate/history.json`
///
/// 关于稳定主键（重点）：
/// `HistoryEntry.id` 是 `"\(date)-\(source.hashValue)"`，Swift 的 hashValue 每次进程启动换随机种子，
/// 同一个 entry 在这次启动和下次启动算出来的 id 不一样，拿它当删除的把手迟早会命中不了。
/// 这里**不改 Contract.swift**，而是本模块自己维护主键：入库时按 `date` 的毫秒时间戳
/// （`String((date.timeIntervalSince1970 * 1000).rounded())`）生成 `Record.id`，同一毫秒冲突时追加
/// `-2`、`-3` 后缀；主键一经写入**永不改动**（去重更新只改 date 字段，不换主键），所以它跨启动、
/// 跨读写都稳定，`remove(id:)` 一定能命中。UI 侧走 `allRecords()` / `records(matching:)` 拿带主键的
/// 记录，`all()` / `search()` 返回的 `HistoryEntry` 只用于展示和重放。
///
/// 其他保证：
/// - **原子写**：先写同目录的隐藏临时文件（写入本身也用 `.atomic`），再 `replaceItem` 整体换掉正式
///   文件。进程被 kill 只会留下临时文件（下次写入前自动清扫），正式文件永远是一份完整 JSON。
/// - **损坏自愈**：JSON 解不出来就改名成 `history.json.broken` 保留现场，从空列表继续，不抛不崩。
/// - **一次性迁移**：文件不存在而 UserDefaults 的 `history` 键里有旧数据时搬进来，迁完删旧键。
/// - 所有“读盘 → 改 → 落盘”在一条串行队列上排队，并发追加不会互相覆盖。
enum HistoryStore {

    // MARK: - 对外接口

    /// 追加一条。相同 source+result+mode 视为同一条：更新它的 date、移到最前，不堆重复记录。
    /// 超出 `maxEntries` 的部分（最旧的尾巴）直接丢弃。
    static func append(_ entry: HistoryEntry) {
        // 设置里关掉保留，这里就真的不再写盘；已有记录保持不动。
        guard Config.shared.keepHistory else { return }
        mutate { records in
            if let idx = records.firstIndex(where: {
                $0.source == entry.source && $0.result == entry.result && $0.mode == entry.mode
            }) {
                // 主键沿用旧的那份：调用方（列表 UI）手里正拿着它，不能因为一次去重就失效。
                let stableID = records[idx].id
                records.remove(at: idx)
                records.insert(Record(entry: entry, id: stableID), at: 0)
            } else {
                let id = makeUniqueID(for: entry.date, taken: records.map { $0.id })
                records.insert(Record(entry: entry, id: id), at: 0)
            }
        }
    }

    /// 按时间倒序（新的在前）。
    static func all() -> [HistoryEntry] {
        allRecords().map { $0.entry }
    }

    /// 清空（写回一份空数组，文件保留）。
    static func clear() {
        mutate { $0 = [] }
    }

    /// 按稳定主键删除单条。主键不存在时静默无操作。
    static func remove(id: String) {
        mutate { records in
            guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
            records.remove(at: idx)
        }
    }

    /// 对 source 和 result 做大小写不敏感的子串匹配；空关键词返回全部。
    static func search(_ keyword: String) -> [HistoryEntry] {
        records(matching: keyword).map { $0.entry }
    }

    /// 历史文件路径，供菜单里“在 Finder 中显示”用。
    static var fileURL: URL { storageDirectory.appendingPathComponent(fileName) }

    // MARK: - 给 UI 的记录级接口（带稳定主键）

    /// 倒序的全部记录。列表要拿这个才能拿到可靠的 `id` 做删除。
    static func allRecords() -> [Record] {
        read { $0 }
    }

    /// 倒序的过滤结果。搜索框即时刷新直接用。
    static func records(matching keyword: String) -> [Record] {
        read { filterMatching($0, keyword: keyword) }
    }

    /// 纯函数版过滤：不读盘。列表已经握着一份全量时用它做即时过滤，省掉每敲一键一次磁盘读。
    static func filterMatching(_ records: [Record], keyword: String) -> [Record] {
        if keyword.isEmpty { return records }
        return records.filter {
            $0.source.localizedCaseInsensitiveContains(keyword)
                || $0.result.localizedCaseInsensitiveContains(keyword)
        }
    }

    // MARK: - 注入点（仅测试用）

    /// 存储目录覆盖。正常调用永远是 nil → 真实 Application Support 路径；
    /// `selfTest()` 期间指向临时目录，保证不碰真实文件。
    static var directoryOverride: URL?

    /// 旧版数据所在的 UserDefaults。nil → `.standard`；测试给独立 suite，避免删掉用户真实旧键。
    static var legacyDefaultsOverride: UserDefaults?

    // MARK: - 常量

    /// 条数上限，超出丢最旧的。
    /// 上限由设置里的「最多留 N 条」决定，0 表示不限。
    /// 以前这里写死 500，界面上的下拉框就成了摆设。
    static var maxEntries: Int {
        let limit = Config.shared.historyLimit
        return limit <= 0 ? .max : limit
    }

    private static let fileName = "history.json"
    private static let legacyKey = "history"
    private static let brokenSuffix = ".broken"
    private static let tempPrefix = ".history.json."
    private static let tempSuffix = ".tmp"

    private static let queue = DispatchQueue(label: "com.localtranslate.history-store", qos: .userInitiated)

    // MARK: - 落盘记录类型

    /// 落盘格式：`HistoryEntry` 的全部字段 + 一个本模块自己维护的 `id`。
    struct Record: Codable, Equatable {
        /// 稳定主键，入库时由 date 生成，之后不再改动。
        var id: String
        var source: String
        var result: String
        var mode: String
        var model: String
        var targetLanguage: String
        var date: Date
        var seconds: Double?

        init(entry: HistoryEntry, id: String) {
            self.id = id
            self.source = entry.source
            self.result = entry.result
            self.mode = entry.mode
            self.model = entry.model
            self.targetLanguage = entry.targetLanguage
            self.date = entry.date
            self.seconds = entry.seconds
        }

        /// 还原成契约类型（`HistoryEntry.id` 仍然是那个不稳定的计算属性，只用于展示/重放）。
        var entry: HistoryEntry {
            HistoryEntry(
                source: source,
                result: result,
                mode: mode,
                model: model,
                targetLanguage: targetLanguage,
                date: date,
                seconds: seconds
            )
        }
    }

    // MARK: - 编解码

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - 路径

    private static var storageDirectory: URL {
        if let override = directoryOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("LocalTranslate", isDirectory: true)
    }

    // MARK: - 读写核心

    private static func read(_ body: ([Record]) -> [Record]) -> [Record] {
        queue.sync { body(load()) }
    }

    /// 读盘 → 改 → 截断 → 落盘，整个过程在串行队列里一次完成。
    private static func mutate(_ body: (inout [Record]) -> Void) {
        queue.sync {
            var records = load()
            body(&records)
            if records.count > maxEntries {
                records = Array(records.prefix(maxEntries))   // 新的在前，尾巴就是最旧的
            }
            save(records)
        }
    }

    /// 返回新→旧顺序的记录。文件不存在时先尝试旧版迁移。
    private static func load() -> [Record] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return migrateLegacyIfNeeded()
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        if data.isEmpty { return [] }
        do {
            return normalized(try decoder.decode([Record].self, from: data))
        } catch {
            quarantineBrokenFile(at: url)
            return []
        }
    }

    /// 排序兜底：新→旧；date 相同再按主键字典序，保证多次读到的顺序一致。顺带去掉同主键的脏数据。
    private static func normalized(_ records: [Record]) -> [Record] {
        var seen = Set<String>()
        let unique = records.filter { seen.insert($0.id).inserted }
        return unique.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }

    private static func save(_ records: [Record]) {
        let fm = FileManager.default
        let dir = storageDirectory
        let url = dir.appendingPathComponent(fileName)
        let temp = dir.appendingPathComponent("\(tempPrefix)\(UUID().uuidString)\(tempSuffix)")

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            removeStaleTempFiles(in: dir)

            let data = try encoder.encode(records)
            // 第一段：临时文件本身用 .atomic 写，保证它内容完整。
            try data.write(to: temp, options: [.atomic])
            // 第二段：整体替换。同卷 rename，读侧永远看不到半截文件。
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItem(at: url, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
            // replaceItem 成功即消费掉 temp；万一线程被 kill，残留文件下次写入前会被清扫。
            if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }
        } catch {
            try? fm.removeItem(at: temp)
            NSLog("[LocalTranslate] 历史写入失败: %@", String(describing: error))
        }
    }

    /// 清扫上一次崩溃留下的同前缀临时文件。
    private static func removeStaleTempFiles(in dir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(tempPrefix) && name.hasSuffix(tempSuffix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 坏文件改名保留现场（已有 .broken 就覆盖，只留最近一次事故），然后从空列表继续。
    private static func quarantineBrokenFile(at url: URL) {
        let fm = FileManager.default
        let broken = url.appendingPathExtension("broken")
        try? fm.removeItem(at: broken)
        do {
            try fm.moveItem(at: url, to: broken)
            NSLog("[LocalTranslate] 历史文件损坏，已备份为 %@", broken.lastPathComponent)
        } catch {
            NSLog("[LocalTranslate] 历史文件损坏且无法备份: %@", String(describing: error))
        }
    }

    // MARK: - 主键生成

    /// date 的毫秒时间戳字符串；同一毫秒已有主键时追加 `-2` / `-3` 后缀。
    private static func makeUniqueID(for date: Date, taken: [String]) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        let stem = String(format: "%.0f", ms)
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    // MARK: - 一次性迁移（旧版 UserDefaults）

    /// 文件不存在时调用。旧格式：`[[String: String]]`，字段 source / result / date（ISO8601 字符串）。
    /// 旧数据没有 mode / model / targetLanguage / seconds：mode 补 "translate"（旧版只有翻译这一种），
    /// 其余留空。迁移成功后立刻删旧键，保证只发生一次。
    private static func migrateLegacyIfNeeded() -> [Record] {
        let defaults = legacyDefaultsOverride ?? UserDefaults.standard
        guard let raw = legacyRaw(from: defaults), !raw.isEmpty else { return [] }
        let records = records(fromLegacy: raw)
        // 解不出任何一条也把旧键删掉：垃圾数据不值得每次都重试。
        defaults.removeObject(forKey: legacyKey)
        guard !records.isEmpty else { return [] }
        save(records)
        NSLog("[LocalTranslate] 已从旧版 UserDefaults 迁移 %d 条历史", records.count)
        return records
    }

    private static func legacyRaw(from defaults: UserDefaults) -> [[String: String]]? {
        defaults.array(forKey: legacyKey) as? [[String: String]]
    }

    /// 纯函数：旧字典数组 → 新记录。字段缺失或日期解不开的条目跳过。
    static func records(fromLegacy raw: [[String: String]]) -> [Record] {
        var out: [Record] = []
        for item in raw {
            guard let source = item["source"], let result = item["result"] else { continue }
            guard let date = parseLegacyDate(item["date"]) else { continue }
            let id = makeUniqueID(for: date, taken: out.map { $0.id })
            out.append(Record(
                entry: HistoryEntry(
                    source: source,
                    result: result,
                    mode: "translate",
                    model: "",
                    targetLanguage: "",
                    date: date,
                    seconds: nil
                ),
                id: id
            ))
        }
        return normalized(out)
    }

    private static func parseLegacyDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = iso8601Strict.date(from: string) { return date }
        if let date = iso8601Plain.date(from: string) { return date }
        if let date = legacyFallbackFormatter.date(from: string) { return date }
        return nil
    }

    private static let iso8601Strict: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let legacyFallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: - 自测

    /// 在临时目录里跑一遍：增删改查、倒序、稳定主键、上限截断、重复去重、损坏文件恢复、
    /// 半截 JSON、搜索大小写不敏感、旧版迁移、原子写留下的临时文件清扫、JSON 编码格式。
    ///
    /// 全程通过 `directoryOverride` + `legacyDefaultsOverride` 隔离在临时目录和独立
    /// UserDefaults suite 里，不碰真实历史文件和用户真实旧键；结束时恢复注入点并删掉临时目录。
    ///
    /// 返回失败描述数组，空数组代表全部通过。
    static func selfTest() -> [String] {
        let savedDirectory = directoryOverride
        let savedLegacy = legacyDefaultsOverride
        defer {
            directoryOverride = savedDirectory
            legacyDefaultsOverride = savedLegacy
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalTranslateHistorySelfTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suiteName = "LocalTranslateHistorySelfTest-\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: suiteName)
        legacyDefaultsOverride = legacyDefaults
        defer {
            legacyDefaults?.removeObject(forKey: legacyKey)
            legacyDefaults?.removePersistentDomain(forName: suiteName)
        }

        var failures: [String] = []

        /// 每个用例一个干净目录，互不影响。
        func scenario(_ name: String, _ body: () -> [String]) {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            directoryOverride = dir
            for message in body() {
                failures.append("[\(name)] \(message)")
            }
            try? fm.removeItem(at: dir)
        }

        // 1) 增删改查 + 倒序 + 稳定主键
        scenario("crud-and-stable-id") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            check(fileURL.lastPathComponent == "history.json", "fileURL 应指向 history.json，实际 \(fileURL.path)")
            check(fileURL.deletingLastPathComponent().path == directoryOverride?.path ?? "", "fileURL 没有走 directoryOverride")
            check(all().isEmpty, "全新环境应该是 0 条，实际 \(all().count) 条")

            append(makeEntry("Apple", "苹果", date: base))
            append(makeEntry("Banana", "香蕉", date: base.addingTimeInterval(60)))
            append(makeEntry("Cherry", "樱桃", mode: "polish", date: base.addingTimeInterval(120)))
            let afterAppend = allRecords()
            check(afterAppend.count == 3, "追加 3 条后应有 3 条，实际 \(afterAppend.count)")
            check(afterAppend.map { $0.source } == ["Cherry", "Banana", "Apple"], "倒序不对：\(afterAppend.map { $0.source })")
            check(all().count == afterAppend.count, "all() 与 allRecords() 条数不一致")
            check(afterAppend[2].entry.mode == "polish" || afterAppend[0].entry.mode == "polish", "mode 字段没有往返")

            // 主键稳定：重读磁盘、再追加新条目，旧主键都不能变
            let ids = afterAppend.map { $0.id }
            check(Set(ids).count == 3, "主键出现重复：\(ids)")
            check(allRecords().map { $0.id } == ids, "重读磁盘后主键变了")
            check(allRecords().allSatisfy { $0.id == String(format: "%.0f", ($0.date.timeIntervalSince1970 * 1000).rounded()) },
                  "主键应等于 date 的毫秒时间戳：\(ids)")
            append(makeEntry("Date", "日期", date: base.addingTimeInterval(180)))
            check(allRecords().count == 4, "追加后条数不对：\(allRecords().count)")
            for expected in ids {
                check(allRecords().contains { $0.id == expected }, "追加新记录后旧主键 \(expected) 消失了")
            }
            check(allRecords().allSatisfy { $0.id != HistoryEntry(source: "Apple", result: "苹果", mode: "translate", model: "", targetLanguage: "", date: base, seconds: nil).id },
                  "主键不应采用 HistoryEntry.id 的 hashValue 方案")

            // 同毫秒不同内容：后缀避让，两条都留
            append(makeEntry("Elderberry", "接骨木", date: base.addingTimeInterval(180)))
            let sameMs = allRecords().filter { $0.date == base.addingTimeInterval(180) }
            check(sameMs.count == 2, "同毫秒的两条都应保留，实际 \(sameMs.count)")
            check(Set(sameMs.map { $0.id }).count == 2, "同毫秒主键没有冲突避让：\(sameMs.map { $0.id })")
            check(Set(allRecords().map { $0.id }).count == allRecords().count, "全局主键不唯一")

            // 删除单条
            let totalBeforeDelete = allRecords().count
            let victim = allRecords()[1]
            remove(id: victim.id)
            check(allRecords().count == totalBeforeDelete - 1, "删除一条后条数没减")
            check(allRecords().first { $0.id == victim.id } == nil, "remove(id:) 没有命中目标记录")
            remove(id: "no-such-id")
            check(allRecords().count == totalBeforeDelete - 1, "删除不存在的主键不应改动数据")

            // 清空
            check(!all().isEmpty, "clear 前应有数据")
            clear()
            check(all().isEmpty, "clear() 没有清空")
            check(allRecords().isEmpty, "clear() 后 allRecords() 仍有数据")

            // 落盘格式：ISO8601 + prettyPrinted + sortedKeys，且目录里不留临时文件
            append(makeEntry("format", "格式", date: base))
            let text = (try? Data(contentsOf: fileURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check(text.contains("\n"), "输出不是 prettyPrinted")
            check(text.contains("\"date\" : \"20"), "日期不是 ISO8601 字符串：\(text.prefix(160))")
            if let idIdx = text.range(of: "\"id\"")?.lowerBound, let srcIdx = text.range(of: "\"source\"")?.lowerBound {
                check(idIdx < srcIdx, "键没有按 sortedKeys 排序")
            } else {
                check(false, "JSON 里找不到 id / source 键")
            }
            let leftovers = (try? fm.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path))?.filter {
                $0.hasPrefix(tempPrefix) && $0.hasSuffix(tempSuffix)
            } ?? []
            check(leftovers.isEmpty, "目录里残留临时文件：\(leftovers)")
            return f
        }

        // 2) 重复去重
        scenario("dedup") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            append(makeEntry("Banana", "香蕉", date: base))
            append(makeEntry("Apple", "苹果", date: base.addingTimeInterval(60)))
            let bananaID = allRecords().first { $0.source == "Banana" }?.id ?? ""
            check(!bananaID.isEmpty, "没能取到 Banana 那条的主键")
            let countBefore = allRecords().count

            let later = base.addingTimeInterval(300)
            append(makeEntry("Banana", "香蕉", date: later))
            check(allRecords().count == countBefore, "同 source+result+mode 不应该新增记录（\(countBefore) → \(allRecords().count)）")
            check(allRecords().first?.source == "Banana", "去重后那条应该移到最前")
            check(allRecords().first?.date == later, "去重后那条的时间应该被更新")
            check(allRecords().first?.id == bananaID, "去重时主键应保持不变，实际 \(allRecords().first?.id ?? "nil")")
            // 更新后拿旧 id 依然能删
            remove(id: bananaID)
            check(allRecords().count == countBefore - 1, "去重更新后按旧主键删除失败")

            // 同 source 不同 result / 不同 mode 都不该合并
            clear()   // 上面删剩了一条 Apple，这里从零开始才好数
            append(makeEntry("Cherry", "樱桃1", date: base))
            append(makeEntry("Cherry", "樱桃2", date: base.addingTimeInterval(1)))
            check(allRecords().count == 2, "同原文不同译文应该各留一条，实际 \(allRecords().count)")
            append(makeEntry("Cherry", "樱桃1", mode: "summarize", date: base.addingTimeInterval(2)))
            check(allRecords().count == 3, "同原文译文但 mode 不同应该单独成条，实际 \(allRecords().count)")
            append(makeEntry("Cherry", "樱桃1", mode: "polish", date: base.addingTimeInterval(3)))
            check(allRecords().count == 4, "mode=polish 也该单独成条，实际 \(allRecords().count)")
            // 三种 mode 的 Cherry 各自置顶，互不覆盖
            append(makeEntry("Cherry", "樱桃1", mode: "polish", date: base.addingTimeInterval(9)))
            check(allRecords().count == 4, "polish 再触发一次不该新增，实际 \(allRecords().count)")
            check(allRecords().first?.mode == "polish", "最后触发的 polish 那条应在最前")
            return f
        }

        // 3) 上限截断
        scenario("cap") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for i in 0..<(maxEntries + 20) {
                append(makeEntry("src-\(i)", "res-\(i)", date: base.addingTimeInterval(Double(i) * 1000)))
            }
            check(allRecords().count == maxEntries, "上限截断失败：\(allRecords().count) 条（应为 \(maxEntries)）")
            check(allRecords().first?.source == "src-\(maxEntries + 19)", "最新一条应在最前，实际 \(allRecords().first?.source ?? "nil")")
            check(!allRecords().contains { $0.source == "src-0" }, "最旧的 src-0 应该被丢掉")
            check(allRecords().last?.source == "src-20", "src-20 应该成为新的最旧记录，实际 \(allRecords().last?.source ?? "nil")")
            // 去重不能把上限撑大
            for i in 0..<10 {
                append(makeEntry("src-\(maxEntries + 19)", "res-\(maxEntries + 19)", date: base.addingTimeInterval(Double(maxEntries + 19) * 1000 + Double(i))))
            }
            check(allRecords().count == maxEntries, "反复去重后条数应仍是上限，实际 \(allRecords().count)")
            return f
        }

        // 4) 搜索
        scenario("search") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            append(makeEntry("Hello World", "你好世界", date: base))
            append(makeEntry("goodbye", "再见 Moon", date: base.addingTimeInterval(10)))
            append(makeEntry("独立", "independent text", mode: "polish", date: base.addingTimeInterval(20)))

            check(search("hello").count == 1, "小写关键词应命中 source 里的大写写法，实际 \(search("hello").count)")
            check(search("WORLD").count == 1, "大写关键词应命中 source 的小写写法")
            check(search("HeLLo WoRLd").count == 1, "混合大小写应命中")
            check(search("moon").count == 1, "关键词应也匹配 result")
            check(search("再见").count == 1, "中文关键词应命中 result")
            check(search("independent").count == 1, "应命中第三条约 text")
            check(search("").count == 3, "空关键词应返回全部，实际 \(search("").count)")
            check(search("zzz").isEmpty, "不存在的关键词应返回空")
            check(search("hello").first?.result == "你好世界", "搜索结果内容不对")
            check(records(matching: "hello").first?.id == allRecords().last?.id, "records(matching:) 与 allRecords() 主键不一致")
            check(search("独立").count == 1, "source 里的中文也应匹配")
            return f
        }

        // 5) 损坏文件恢复
        scenario("broken-file") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let garbage = Data("this is ] not [ json".utf8)
            try? garbage.write(to: fileURL)

            check(all().isEmpty, "损坏文件应读到空列表，而不是崩溃或半截数据")
            let broken = fileURL.appendingPathExtension("broken")
            check(broken.lastPathComponent == "history.json.broken", "备份文件名不对：\(broken.lastPathComponent)")
            check(fm.fileExists(atPath: broken.path), "损坏文件没有备份成 history.json.broken")
            check((try? Data(contentsOf: broken)) == garbage, "备份内容与原坏数据不一致")
            check(!fm.fileExists(atPath: fileURL.path), "坏文件本体应该已被移走")

            append(makeEntry("after", "恢复", date: base))
            check(all().count == 1, "损坏恢复后应能继续写入，实际 \(all().count)")
            let reread = all()
            check(reread.count == 1 && reread.first?.source == "after", "损坏恢复后重读结果不对")

            // 第二次损坏：只覆盖那一份 .broken，不产生一堆备份
            try? garbage.write(to: fileURL)
            _ = all()
            let brokenCount = ((try? fm.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)) ?? [])
                .filter { $0.hasSuffix(brokenSuffix) }.count
            check(brokenCount == 1, "损坏备份应只留最近一份，实际 \(brokenCount)")

            // 半截 JSON（模拟写到一半被 kill）
            append(makeEntry("keep", "保留", date: base.addingTimeInterval(5)))
            let full = String(data: (try? Data(contentsOf: fileURL)) ?? Data(), encoding: .utf8) ?? ""
            check(full.count > 20, "上一步写入的 JSON 太短，无法构造半截用例")
            try? Data(String(full.prefix(full.count / 2)).utf8).write(to: fileURL)
            check(all().isEmpty, "半截 JSON 应读到空列表")
            check(fm.fileExists(atPath: fileURL.appendingPathExtension("broken").path), "半截 JSON 也应被备份")
            return f
        }

        // 6) 旧版 UserDefaults 一次性迁移
        scenario("legacy-migration") {
            var f: [String] = []
            func check(_ ok: Bool, _ message: String) { if !ok { f.append(message) } }
            let defaults = legacyDefaultsOverride ?? UserDefaults.standard
            let legacy: [[String: String]] = [
                ["source": "old-one", "result": "旧一", "date": "2024-01-02T03:04:05Z"],
                ["source": "old-two", "result": "旧二", "date": "2024-01-01T00:00:00Z"],
                ["source": "no-date", "result": "缺日期"],
                ["result": "缺原文", "date": "2024-01-03T00:00:00Z"],
                ["source": "坏日期", "result": "x", "date": "昨天"],
            ]

            // 前置：文件不存在 + 有旧数据
            try? fm.removeItem(at: fileURL)
            defaults.set(legacy, forKey: legacyKey)
            let migrated = allRecords()
            check(migrated.count == 2, "迁移应只搬来可解析的 2 条，实际 \(migrated.count)")
            check(migrated.first?.source == "old-one", "迁移后仍应按时间倒序：\(migrated.map { $0.source })")
            check(migrated.allSatisfy { $0.mode == "translate" }, "旧数据应补 mode=translate")
            check(migrated.allSatisfy { $0.model.isEmpty && $0.targetLanguage.isEmpty }, "旧数据的 model / 语言应留空")
            check(migrated.allSatisfy { !$0.id.isEmpty }, "迁移记录没有生成稳定主键")
            check(migrated.allSatisfy { $0.seconds == nil }, "旧数据不该有耗时")
            check(defaults.array(forKey: legacyKey) == nil, "迁移后旧键没有被删除")
            check(fm.fileExists(atPath: fileURL.path), "迁移结果没有落盘")

            // 迁移来的记录照样可以按主键删除
            let firstID = migrated[0].id
            remove(id: firstID)
            check(allRecords().count == 1, "迁移来的记录按主键删除失败")

            // 文件已存在 → 即使旧键又被写回也不再二次迁移
            append(makeEntry("newer", "更新", date: Date(timeIntervalSince1970: 1_700_000_000)))
            let countAfterAppend = allRecords().count
            defaults.set(legacy, forKey: legacyKey)
            check(allRecords().count == countAfterAppend, "文件存在时不应再次迁移")
            check(defaults.array(forKey: legacyKey) != nil, "未触发迁移时不该顺手删旧键")

            // 全是垃圾的旧数据：解析不出条目也要删键，避免每次重试
            try? fm.removeItem(at: fileURL)
            defaults.set([["bogus": "x"]], forKey: legacyKey)
            check(all().isEmpty, "全垃圾旧数据应读到空列表")
            check(defaults.array(forKey: legacyKey) == nil, "解析不出条目时也应删除旧键")

            // 旧键不存在且文件不存在 → 空，不创建文件
            defaults.removeObject(forKey: legacyKey)
            try? fm.removeItem(at: fileURL)
            check(all().isEmpty, "无文件无旧数据应为空")
            check(!fm.fileExists(atPath: fileURL.path), "只读操作不该凭空创建历史文件")

            // 日期兼容：带小数秒 + "yyyy-MM-dd HH:mm:ss"
            let parsed = records(fromLegacy: [
                ["source": "a", "result": "b", "date": "2024-05-06T07:08:09.123Z"],
                ["source": "c", "result": "d", "date": "2024-05-05 06:07:08"],
            ])
            check(parsed.count == 2, "旧日期多格式兼容失败，实际 \(parsed.count)")
            check(parsed.first?.source == "a", "带小数秒的那条应更新")

            // 纯函数入口
            check(records(fromLegacy: []).isEmpty, "空旧数据不应解析出记录")
            check(records(fromLegacy: [["bogus": "x"]]).isEmpty, "字段不全的旧条目应被跳过")
            return f
        }

        return failures
    }

    /// 自测用的样本构造。
    private static func makeEntry(_ source: String,
                                  _ result: String,
                                  mode: String = "translate",
                                  model: String = "gpt-4o-mini",
                                  lang: String = "zh-Hans",
                                  date: Date,
                                  seconds: Double? = 1.5) -> HistoryEntry {
        HistoryEntry(source: source, result: result, mode: mode, model: model,
                     targetLanguage: lang, date: date, seconds: seconds)
    }
}
