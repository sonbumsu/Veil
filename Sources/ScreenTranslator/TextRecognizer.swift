import Vision
import VideoToolbox

/// 화면에서 읽은 한 줄 또는 세로쓰기 한 열 (좌표는 화면 포인트, 왼쪽 위 기준)
struct TextLine: Sendable {
    let text: String
    let rect: CGRect

    /// 세로쓰기(일본어·중국어) 열인지. 글자가 2개 이상인데 세로로 길쭉하면 세로쓰기로 봐요.
    var isVertical: Bool { text.count > 1 && rect.height > rect.width * 1.5 }
}

/// 여러 줄(열)을 묶은 문단
struct Paragraph: Sendable {
    let text: String
    let rect: CGRect
    /// 원문 글자 크기 추정치 (가로쓰기는 줄 높이, 세로쓰기는 열 너비 기준)
    let fontSize: CGFloat
    let isVertical: Bool
    /// 화면에서 뽑은 원문 배경색·글자색 (ColorSampler가 채워요)
    var background: RGB?
    var foreground: RGB?
    /// 원문 글자만 지운 배경 그림 (ColorSampler가 채워요)
    var patch: BackgroundPatch?
}

enum TextRecognizer {
    static func recognize(_ pixelBuffer: CVPixelBuffer, screenSize: CGSize) async throws -> [TextLine] {
        convert(try await makeRequest().perform(on: pixelBuffer), size: screenSize, offsetY: 0)
    }

    static func recognize(_ image: CGImage, screenSize: CGSize) async throws -> [TextLine] {
        convert(try await makeRequest().perform(on: image), size: screenSize, offsetY: 0)
    }

    /// 화면 중 가로 띠(`band`, 포인트) 부분만 읽어요. 띠가 얇을수록 빨라요.
    static func recognize(_ pixelBuffer: CVPixelBuffer, band: ClosedRange<CGFloat>,
                          screenSize: CGSize, scale: CGFloat) async throws -> [TextLine] {
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &full)
        let y0 = max(0, band.lowerBound), y1 = min(screenSize.height, band.upperBound)
        guard let full, y1 - y0 >= 4,
              let crop = full.cropping(to: CGRect(x: 0, y: (y0 * scale).rounded(.down),
                                                  width: CGFloat(full.width),
                                                  height: ((y1 - y0) * scale).rounded(.up)))
        else { return [] }
        let size = CGSize(width: screenSize.width, height: CGFloat(crop.height) / scale)
        // 최소 글자 높이는 화면 전체 기준과 똑같은 실제 크기로 맞춰요.
        let fraction = Float(min(0.5, 0.008 * screenSize.height / size.height))
        return convert(try await makeRequest(minimumTextHeight: fraction).perform(on: crop),
                       size: size, offsetY: (y0 * scale).rounded(.down) / scale)
    }

    private static func makeRequest(minimumTextHeight: Float = 0.008) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false      // 끄면 약 25% 빨라요. 번역에는 영향이 거의 없어요.
        request.minimumTextHeightFraction = minimumTextHeight   // 작은 UI 글씨도 잡히게
        return request
    }

    private static func convert(_ observations: [RecognizedTextObservation], size: CGSize, offsetY: CGFloat) -> [TextLine] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.3 else { return nil }
            let rect = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            return TextLine(text: candidate.string, rect: rect.offsetBy(dx: 0, dy: offsetY))
        }
    }
}

/// 이어지는 줄(열)들을 하나의 문단으로 합칩니다.
/// 줄 단위로 번역하면 문장이 중간에 잘려서 번역 품질이 크게 떨어지기 때문이에요.
///  - 가로쓰기: 위→아래로 쌓이고 왼쪽 정렬이 비슷한 줄
///  - 세로쓰기: 오른쪽→왼쪽으로 이어지고 위쪽 정렬이 비슷한 열
enum ParagraphBuilder {
    static func build(from lines: [TextLine]) -> [Paragraph] {
        group(lines.filter { !$0.isVertical }, vertical: false)
            + group(lines.filter(\.isVertical), vertical: true)
    }

    private static func group(_ lines: [TextLine], vertical: Bool) -> [Paragraph] {
        let sorted = vertical
            ? lines.sorted { $0.rect.maxX > $1.rect.maxX }    // 오른쪽 열부터
            : lines.sorted { $0.rect.minY < $1.rect.minY }    // 위쪽 줄부터

        var drafts: [[TextLine]] = []
        for line in sorted {
            let match = drafts.lastIndex { draft in
                continues(from: draft[draft.count - 1].rect, to: line.rect, vertical: vertical)
            }
            if let match {
                drafts[match].append(line)
            } else {
                drafts.append([line])
            }
        }

        return drafts.map { lines in
            let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
            let thickness = lines.map { vertical ? $0.rect.width : $0.rect.height }.sorted()
            let median = thickness[thickness.count / 2]
            return Paragraph(text: join(lines.map(\.text)),
                             rect: rect,
                             fontSize: median * (vertical ? 0.72 : 0.8),
                             isVertical: vertical)
        }
    }

    /// `next` 줄이 `prev` 줄에 이어지는 줄인지
    private static func continues(from prev: CGRect, to next: CGRect, vertical: Bool) -> Bool {
        if vertical {
            let w = next.width
            let gap = prev.minX - next.maxX                       // 다음 열은 왼쪽에 있어야 함
            return (0.6...1.6).contains(w / max(prev.width, 1))
                && abs(next.minY - prev.minY) < w * 1.5           // 위쪽이 맞춰져 있음
                && gap > -w * 0.3 && gap < w * 0.8
        } else {
            let h = next.height
            let gap = next.minY - prev.maxY                       // 다음 줄은 아래에 있어야 함
            return (0.7...1.4).contains(h / max(prev.height, 1))
                && abs(next.minX - prev.minX) < h * 1.5           // 왼쪽이 맞춰져 있음
                && gap > -h * 0.3 && gap < h * 0.8
        }
    }

    private static func join(_ texts: [String]) -> String {
        texts.dropFirst().reduce(texts[0]) { result, next in
            if result.hasSuffix("-") {
                return String(result.dropLast()) + next          // 하이픈으로 끊긴 영어 단어
            }
            if let last = result.last, isCJK(last) {
                return result + next                              // 중국어·일본어는 띄어쓰기 없음
            }
            return result + " " + next
        }
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            (0x3000...0x30FF).contains($0.value)       // 일본어 문장부호·히라가나·가타카나
            || (0x4E00...0x9FFF).contains($0.value)    // 한자
            || (0xFF00...0xFFEF).contains($0.value)    // 전각 문자 (！？ 등)
        }
    }
}
