import Foundation
import Translation

/// 화면의 문단들 중 "지금 가장 필요한 것"부터 하나씩 번역하고, 끝날 때마다 바로 화면에 반영해요.
///  - 마우스 근처(지금 읽는 곳)부터
///  - 화면 끝에 잘려 있는 문단은 맨 나중에 (스크롤하면 내용이 바뀌니까)
///  - 스크롤해서 화면 밖으로 나간 문단은 건너뜀
actor TranslationQueue {
    private static let cacheLimit = 3000
    private static let statusTTL: TimeInterval = 10

    private let state: OverlayState
    private let screenSize: CGSize
    private let wakeStream: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    private var cache: [String: String] = [:]   // 원문 → 번역문 (디스크에도 저장돼서 앱을 다시 켜도 남아요)
    private var cacheOrder: [String] = []        // 오래된 것부터
    private var unsaved = 0
    private var lastSave = Date()
    private var skip: Set<String> = []           // 번역 안 할 글 (언어 판별 불가, 미지원, 반복 실패)
    private var failures: [String: Int] = [:]
    private var statuses: [String: (status: LanguageAvailability.Status, fast: Bool, checked: Date)] = [:]

    // 가장 최근 프레임의 상태
    private var paragraphs: [Paragraph] = []
    private var languages: [String: Locale.Language] = [:]   // 원문 → 언어
    private var frameIndex = 0
    private var focus: CGPoint = .zero
    /// 최근에 화면에 보여준 원문들 (글자 인식이 한두 글자 다르게 읽어도 같은 번역을 이어서 보여주려고)
    private var recentlyShown: [String] = []
    /// 비슷한 원문의 번역을 임시로 보여주는 중인 글 → 그 원문
    private var provisional: [String: String] = [:]

    init(state: OverlayState, screenSize: CGSize) {
        self.state = state
        self.screenSize = screenSize
        (wakeStream, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        for (source, translated) in TranslationStore.load() where cache[source] == nil {
            cache[source] = translated
            cacheOrder.append(source)
        }
    }

    /// 새 프레임의 인식 결과를 반영하고, 이미 번역된 건 바로 표시해요.
    func update(paragraphs: [Paragraph], frameIndex: Int, focus: CGPoint) async {
        self.paragraphs = paragraphs
        self.frameIndex = frameIndex
        self.focus = focus

        let foreign = paragraphs.map(\.text).filter(Translator.needsTranslation)
        let dominant = Translator.dominantLanguage(of: foreign)
        languages = [:]
        for text in foreign where languages[text] == nil {
            languages[text] = Translator.language(of: text, fallback: dominant)
        }

        await publish()
        wake.yield()
    }

    func run() async {
        await Translator.prewarm()
        for await _ in wakeStream {
            while !Task.isCancelled, let (text, language, fast) = await nextItem() {
                do {
                    remember(text, try await Translator.translate(text, from: language, fast: fast))
                } catch {
                    failures[text, default: 0] += 1
                    if failures[text, default: 0] >= 2 { skip.insert(text) }
                }
                if skip.count > Self.cacheLimit { skip.removeAll() }
                await publish()
            }
        }
    }

    func stop() {
        wake.finish()
        save()
    }

    private func remember(_ source: String, _ translated: String) {
        if cache.updateValue(translated, forKey: source) == nil { cacheOrder.append(source) }
        if cacheOrder.count > Self.cacheLimit {                 // 오래된 것부터 정리
            for old in cacheOrder.prefix(500) { cache[old] = nil }
            cacheOrder.removeFirst(500)
        }
        unsaved += 1
        if unsaved >= 20 || Date().timeIntervalSince(lastSave) > 10 { save() }
    }

    private func save() {
        guard unsaved > 0 else { return }
        TranslationStore.save(cacheOrder.compactMap { source in cache[source].map { (source, $0) } })
        unsaved = 0
        lastSave = Date()
    }

    // MARK: -

    private func isWaiting(_ text: String) -> Bool {
        cache[text] == nil && !skip.contains(text) && languages[text] != nil
    }

    private func nextItem() async -> (String, Locale.Language, Bool)? {
        let candidates = paragraphs
            .filter { isWaiting($0.text) }
            .sorted { priority($0) < priority($1) }
        for paragraph in candidates {
            guard isWaiting(paragraph.text), let language = languages[paragraph.text] else { continue }
            let (status, fast) = await status(of: language)
            switch status {
            case .installed: return (paragraph.text, language, fast)
            case .supported: continue                  // 언어 팩 없음 → 안내만
            default: skip.insert(paragraph.text)
            }
        }
        return nil
    }

    private func priority(_ p: Paragraph) -> CGFloat {
        let dx = max(p.rect.minX - focus.x, 0, focus.x - p.rect.maxX)
        let dy = max(p.rect.minY - focus.y, 0, focus.y - p.rect.maxY)
        var score = (dx * dx + dy * dy).squareRoot()
        if p.rect.minY < 2 || p.rect.maxY > screenSize.height - 2 { score += 10_000 }
        if provisional[p.text] != nil { score += 5_000 }   // 이미 비슷한 번역이 떠 있으면 새 글 먼저
        return score
    }

    /// 언어 팩 상태 (10초 캐시). 빠른 모델을 켰고 받아져 있으면 그걸 써요.
    private func status(of language: Locale.Language) async -> (LanguageAvailability.Status, Bool) {
        let key = language.maximalIdentifier
        if let cached = statuses[key], Date().timeIntervalSince(cached.checked) < Self.statusTTL {
            return (cached.status, cached.fast)
        }
        var result: (LanguageAvailability.Status, Bool) = (await Translator.status(of: language, fast: false), false)
        if UserDefaults.standard.bool(forKey: Translator.fastModelKey),
           await Translator.status(of: language, fast: true) == .installed {
            result = (.installed, true)
        }
        statuses[key] = (result.0, result.1, Date())
        return result
    }

    private func publish() async {
        // 정확히 같은 원문의 번역이 없으면, 최근에 보여준 비슷한 원문의 번역을 임시로 써요.
        provisional = [:]
        for p in paragraphs where cache[p.text] == nil {
            if let match = Similarity.bestMatch(for: p.text, in: recentlyShown) { provisional[p.text] = match }
        }

        var seen: [String: Int] = [:]   // 같은 글이 화면에 여러 번 있을 때 id 구분용
        var shownSources: [String] = []
        let blocks = paragraphs.compactMap { p -> TranslatedBlock? in
            let source = cache[p.text] != nil ? p.text : provisional[p.text]
            guard let source, let translated = cache[source] else { return nil }
            shownSources.append(source)
            // id는 번역에 쓴 원문 기준이라, 인식이 살짝 달라져도 같은 블록으로 이어져요.
            let n = seen[source, default: 0]
            seen[source] = n + 1
            return TranslatedBlock(id: "\(n)|\(source)", translated: translated, rect: p.rect,
                                   fontSize: p.fontSize, isVertical: p.isVertical,
                                   background: p.background, foreground: p.foreground, patch: p.patch)
        }
        recentlyShown = Array((shownSources + recentlyShown.filter { !shownSources.contains($0) }).prefix(300))

        let waiting = paragraphs.filter { isWaiting($0.text) && provisional[$0.text] == nil }

        let missing = Set(waiting.compactMap { p -> String? in
            guard let language = languages[p.text],
                  statuses[language.maximalIdentifier]?.status == .supported else { return nil }
            return Translator.displayName(language)
        })
        let notice = missing.isEmpty ? nil : "\(missing.sorted().joined(separator: ", ")) 언어 팩이 없어요 · 메뉴바 › 언어 팩 관리"
        let installedWaiting = waiting.contains { p in
            languages[p.text].map { statuses[$0.maximalIdentifier]?.status != .supported } ?? false
        }

        await state.show(blocks, pending: waiting.map(\.rect), frameIndex: frameIndex,
                         isTranslating: installedWaiting, notice: notice)
    }
}

/// 글자 인식 결과끼리 얼마나 비슷한지 (글자 2개씩 묶은 조각이 얼마나 겹치는지)
enum Similarity {
    static let threshold = 0.75

    static func bestMatch(for text: String, in candidates: [String]) -> String? {
        let a = Array(text.filter { !$0.isWhitespace })
        guard a.count >= 4 else { return nil }
        let aBigrams = bigrams(a)
        let aNumbers = numbers(in: text)   // 숫자가 다르면 다른 글 (12화 ≠ 13화)
        var best: (score: Double, text: String)?
        for candidate in candidates {
            let b = Array(candidate.filter { !$0.isWhitespace })
            guard b.count >= 4, numbers(in: candidate) == aNumbers,
                  Double(min(a.count, b.count)) / Double(max(a.count, b.count)) >= threshold else { continue }
            let score = dice(aBigrams, bigrams(b), total: a.count + b.count - 2)
            if score >= threshold, score > (best?.score ?? 0) { best = (score, candidate) }
        }
        return best?.text
    }

    /// 독립된 숫자들. 영어 글자에 붙은 숫자(Hel1o처럼 l을 1로 잘못 읽은 것)는 빼요.
    private static func numbers(in text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = [], i = 0
        func isLatin(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isLetter } ?? false }
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            if !isLatin(i > 0 ? chars[i - 1] : nil), !isLatin(j < chars.count ? chars[j] : nil) {
                result.append(String(chars[i..<j]))
            }
            i = j
        }
        return result
    }

    private static func bigrams(_ chars: [Character]) -> [String: Int] {
        var result: [String: Int] = [:]
        for i in 0..<(chars.count - 1) { result[String(chars[i]) + String(chars[i + 1]), default: 0] += 1 }
        return result
    }

    private static func dice(_ a: [String: Int], _ b: [String: Int], total: Int) -> Double {
        var common = 0
        for (key, count) in a { common += min(count, b[key] ?? 0) }
        return Double(2 * common) / Double(total)
    }
}

/// 번역 결과를 디스크에 저장해요 (~/Library/Application Support/Veil/translations.json)
enum TranslationStore {
    private static var url: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Veil/translations.json")
        // 예전 이름(ScreenTranslator) 폴더에 저장된 번역이 있으면 옮겨와요.
        let old = URL.applicationSupportDirectory.appending(path: "ScreenTranslator/translations.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: url)
        }
        return url
    }

    static func load() -> [(String, String)] {
        guard let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    static func save(_ pairs: [(String, String)]) {
        guard let data = try? JSONEncoder().encode(pairs.map { [$0.0, $0.1] }) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
