import Foundation
import NaturalLanguage
import Translation

enum Translator {
    static let target = Locale.Language(identifier: "ko")
    /// 언어 팩 창의 "빠른 번역 모델 사용" 설정 키
    static let fastModelKey = "useFastModel"

    /// 한 문장 번역. 시스템 번역은 한 번에 한 문장씩만 처리해서, 여러 개를 묶어도 빨라지지 않아요.
    static func translate(_ text: String, from language: Locale.Language, fast: Bool) async throws -> String {
        let session = fast
            ? TranslationSession(installedSource: language, target: target, preferredStrategy: .lowLatency)
            : TranslationSession(installedSource: language, target: target)
        return try await session.translate(text).targetText
    }

    static func status(of language: Locale.Language, fast: Bool) async -> LanguageAvailability.Status {
        let availability = fast ? LanguageAvailability(preferredStrategy: .lowLatency) : LanguageAvailability()
        return await availability.status(from: language, to: target)
    }

    /// 앱에서 처음 번역할 때는 번역 서비스 준비에 1~2초가 걸려요. 미리 한 번 돌려둬요.
    static func prewarm() async {
        for code in ["en", "ja"] {
            let language = Locale.Language(identifier: code)
            if await status(of: language, fast: false) == .installed {
                _ = try? await translate("Hello", from: language, fast: false)
                return
            }
        }
    }

    static func displayName(_ language: Locale.Language) -> String {
        Locale(identifier: "ko").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    static func needsTranslation(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 2 else { return false }                 // 숫자·기호만 있는 건 건너뜀
        let hangul = letters.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        return Double(hangul) / Double(letters.count) < 0.5           // 이미 한국어인 건 건너뜀
    }

    /// 문단의 언어. 짧은 글("OK", "File")은 판별이 부정확해서 화면 전체의 주 언어(`fallback`)를 써요.
    /// 한국어이거나 알 수 없으면 nil.
    static func language(of text: String, fallback: Locale.Language?) -> Locale.Language? {
        let detected = (text.count >= 20 || containsKana(text)) ? detectLanguage(text) : nil
        guard let language = detected ?? fallback, language.languageCode != .korean else { return nil }
        return language
    }

    static func dominantLanguage(of texts: [String]) -> Locale.Language? {
        detectLanguage(texts.joined(separator: "\n"))
    }

    private static func detectLanguage(_ text: String) -> Locale.Language? {
        // 히라가나·가타카나가 있으면 확실히 일본어 (한자만 보고 중국어로 착각하는 걸 방지)
        if containsKana(text) { return Locale.Language(identifier: "ja") }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
}
