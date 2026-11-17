import AppKit

/// 번역 결과 한 덩어리 (화면에 그릴 단위)
struct TranslatedBlock: Identifiable, Sendable {
    /// 원문 기반 id. 스크롤해도 같은 문단은 같은 id라서 SwiftUI가 같은 뷰로 취급해요.
    let id: String
    let translated: String
    var rect: CGRect
    let fontSize: CGFloat
    let isVertical: Bool
    let background: RGB?
    let foreground: RGB?
    var patch: BackgroundPatch?
    /// 그 자리에 번역이 처음 생기는 거면 살짝 나타나게 해요 (OverlayState가 정해요).
    var fadesIn = false
    /// 스크롤을 놓쳐서 위치를 믿을 수 없는 동안 숨김 (다음 글자 인식 때 제자리로 돌아와요)
    var isHidden = false
}

/// 프레임 → 글자 인식 → 문단·색 추출 → 번역 대기열 갱신을 반복합니다.
/// 번역은 TranslationQueue가 따로 돌면서 하나씩 끝날 때마다 화면에 반영해요.
enum LivePipeline {
    /// 바뀐 띠가 화면의 이 비율을 넘으면 그냥 전체를 읽어요.
    private static let fullScanRatio: CGFloat = 0.5
    /// 부분 인식만 이 횟수 이어지면 한 번은 전체를 읽어서 어긋난 걸 바로잡아요.
    private static let fullScanEvery = 8
    /// 바뀐 곳 위아래로 이만큼 더 읽어요 (줄이 잘리지 않게)
    private static let bandMargin: CGFloat = 24
    /// 띠가 너무 얇으면 글자 인식이 부정확해져서 (측정: 80pt는 놓침, 160pt부터 전체 인식과 같음) 최소 높이를 둬요.
    private static let minBandHeight: CGFloat = 160

    static func run(capture: LiveCapture, screenFrame: CGRect, scale: CGFloat, state: OverlayState) async {
        let queue = TranslationQueue(state: state, screenSize: screenFrame.size)
        let worker = Task { await queue.run() }
        let screenSize = screenFrame.size
        var known: [Paragraph] = []        // 직전 인식 결과 (다음 프레임 위치로 옮겨가며 재사용)
        var partialScans = 0

        for await _ in capture.wakes {
            guard !Task.isCancelled else { break }
            guard let frame = capture.takeFrame() else { continue }

            // 1) 지난번 문단들을 그 사이 스크롤만큼 옮기기
            var extraChanged: [CGRect] = []
            for scroll in frame.scrolls {
                known = known.map { p in
                    var p = p
                    let moved = scroll.apply(to: p.rect)
                    // 스크롤 영역 경계에 걸쳐 잘린 문단은 다시 읽어요
                    if moved != p.rect, !scroll.region.contains(moved) { extraChanged.append(moved) }
                    p = Paragraph(text: p.text, rect: moved, fontSize: p.fontSize, isVertical: p.isVertical,
                                  background: p.background, foreground: p.foreground, patch: p.patch)
                    return p
                }
            }

            let screenRect = CGRect(origin: .zero, size: screenSize)
            known.removeAll { !$0.rect.intersects(screenRect) }   // 화면 밖으로 나간 문단

            // 2) 다시 읽을 가로 띠 정하기
            var bands: [ClosedRange<CGFloat>]?
            if let changed = frame.changed, partialScans < fullScanEvery {
                bands = Self.bands(for: changed + extraChanged, known: known, screenHeight: screenSize.height)
                let total = bands!.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                if total > screenSize.height * fullScanRatio { bands = nil }
            }

            // 3) 글자 인식
            var lines: [TextLine] = []
            if let partial = bands {
                partialScans += 1
                for band in partial {
                    if let found = try? await TextRecognizer.recognize(frame.pixelBuffer, band: band,
                                                                       screenSize: screenSize, scale: scale) {
                        lines += found
                    }
                }
                known.removeAll { p in partial.contains { $0.overlaps(p.rect.minY...p.rect.maxY) } }
                // 띠 경계에 걸쳐 잘린 세로쓰기 열이 있으면 이번엔 전체를 다시 읽어요.
                let cut = lines.contains { line in
                    line.isVertical && partial.contains { band in
                        (band.lowerBound > 0 && line.rect.minY < band.lowerBound + 2)
                            || (band.upperBound < screenSize.height && line.rect.maxY > band.upperBound - 2)
                    }
                }
                if cut { bands = nil; lines = [] }
            }
            if bands == nil {
                partialScans = 0
                guard let found = try? await TextRecognizer.recognize(frame.pixelBuffer, screenSize: screenSize)
                else { continue }
                lines = found
                known = []
            }

            var fresh = ParagraphBuilder.build(from: lines)
            ColorSampler.apply(to: &fresh, pixelBuffer: frame.pixelBuffer, scale: scale)
            known += fresh

            let mouse = await MainActor.run { NSEvent.mouseLocation }
            let focus = CGPoint(x: mouse.x - screenFrame.minX, y: screenFrame.maxY - mouse.y)
            await queue.update(paragraphs: known, frameIndex: frame.index, focus: focus)
        }

        await queue.stop()
        worker.cancel()
    }

    /// 바뀐 곳들을 화면 전체 너비의 가로 띠로 바꾸고, 걸친 문단은 통째로 들어가게 넓혀서 합쳐요.
    static func bands(for changed: [CGRect], known: [Paragraph], screenHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        var bands = changed
            .filter { !$0.isEmpty && $0.height > 0 }
            .map { rect -> ClosedRange<CGFloat> in
                var lo = rect.minY - bandMargin, hi = rect.maxY + bandMargin
                if hi - lo < minBandHeight {
                    let grow = (minBandHeight - (hi - lo)) / 2
                    lo -= grow; hi += grow
                }
                if lo < 0 { hi -= lo; lo = 0 }
                if hi > screenHeight { lo -= hi - screenHeight; hi = screenHeight }
                return max(0, lo)...min(screenHeight, hi)
            }
            .filter { $0.upperBound > $0.lowerBound }

        // 걸친 문단이 잘리지 않게 넓히기 (넓히면 또 걸칠 수 있어서 몇 번 반복)
        for _ in 0..<3 {
            var grew = false
            bands = bands.map { band in
                var band = band
                for p in known where band.overlaps(p.rect.minY...p.rect.maxY) {
                    let wider = min(band.lowerBound, p.rect.minY - 4)...max(band.upperBound, p.rect.maxY + 4)
                    if wider != band { band = wider; grew = true }
                }
                return max(0, band.lowerBound)...min(screenHeight, band.upperBound)
            }
            bands = merge(bands)
            if !grew { break }
        }
        return bands
    }

    private static func merge(_ bands: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for band in bands.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= band.lowerBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, band.upperBound)
            } else {
                result.append(band)
            }
        }
        return result
    }
}
