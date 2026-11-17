import SwiftUI
import Translation

/// 번역 언어 팩 다운로드 상태를 보여주고 받을 수 있게 해요.
/// 언어 팩을 받아두면 오프라인에서도 기기 안에서 번역돼요.
struct LanguageSetupView: View {
    private static let languages: [(code: String, name: String)] = [
        ("en", "영어"), ("ja", "일본어"), ("zh-Hans", "중국어(간체)"), ("zh-Hant", "중국어(번체)"),
        ("es", "스페인어"), ("fr", "프랑스어"), ("de", "독일어"), ("ru", "러시아어"),
    ]

    @AppStorage(Translator.fastModelKey) private var useFastModel = false
    @State private var statuses: [String: LanguageAvailability.Status] = [:]
    @State private var configuration: TranslationSession.Configuration?
    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("외국어 → 한국어 언어 팩").font(.headline)
            Text("받아둔 언어만 번역돼요. 한 번 받으면 오프라인에서도 동작해요.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(isOn: $useFastModel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("빠른 번역 모델 사용")
                    Text("더 빠르지만 품질이 조금 낮을 수 있어요. 언어마다 따로 받아야 하고, 안 받은 언어는 기본 모델로 번역해요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("받는 중에도 번역은 기본 모델로 계속 돼요. 다운로드 속도는 애플 서버와 네트워크에 달려 있어요. 진행 상황은 시스템 설정 › 일반 › 언어 및 지역 › 번역 언어에서 볼 수 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(Self.languages, id: \.code) { language in
                HStack {
                    Text(language.name)
                    Spacer()
                    statusView(for: language.code)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .task(id: useFastModel) {
            statuses = [:]
            await refresh()
        }
        .translationTask(configuration) { @concurrent session in
            try? await session.prepareTranslation()   // 시스템 다운로드 안내 창이 떠요
            await refresh()
            await finishDownloads()
        }
    }

    @ViewBuilder
    private func statusView(for code: String) -> some View {
        if downloading.contains(code) && statuses[code] != .installed {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("받는 중…").foregroundStyle(.secondary)
            }
        } else {
            statusBadge(for: code)
        }
    }

    @ViewBuilder
    private func statusBadge(for code: String) -> some View {
        switch statuses[code] {
        case .installed:
            Label("설치됨", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .supported:
            Button(useFastModel ? "빠른 모델 받기" : "받기") {
                downloading.insert(code)
                let source = Locale.Language(identifier: code)
                configuration = useFastModel
                    ? .init(source: source, target: Translator.target, preferredStrategy: .lowLatency)
                    : .init(source: source, target: Translator.target)
            }
        case .unsupported:
            Text("지원 안 됨").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small)
        }
    }

    /// 다운로드 안내 창을 닫았거나 다운로드가 끝나면 "받는 중" 표시를 정리해요.
    private func finishDownloads() {
        downloading = []
    }

    private func refresh() async {
        let fast = useFastModel
        for language in Self.languages {
            statuses[language.code] = await Translator.status(of: Locale.Language(identifier: language.code), fast: fast)
        }
    }
}
