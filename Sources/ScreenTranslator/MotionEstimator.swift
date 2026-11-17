import CoreVideo
import Foundation

/// 화면을 "가로줄마다 밝기 몇 칸"으로 요약한 지문.
/// 두 프레임의 지문을 위아래로 밀어 보면서 가장 잘 맞는 위치를 찾으면 스크롤 양을 알 수 있어요.
struct RowProfile: Sendable {
    static let rowStep = 2      // 2픽셀마다 한 줄
    static let bins = 32        // 한 줄을 가로 32칸으로 나눠 평균 밝기
    static let columnStep = 4   // 칸 안에서 4픽셀마다 샘플

    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let data: [Float]           // rows × bins

    var binWidth: Double { Double(pixelWidth) / Double(Self.bins) }

    init(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rows = height / Self.rowStep
        let bins = Self.bins
        var data = [Float](repeating: 0, count: rows * bins)

        if let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) {
            let binWidth = width / bins
            for r in 0..<rows {
                let row = base + r * Self.rowStep * bytesPerRow
                for b in 0..<bins {
                    var sum = 0, count = 0
                    var x = b * binWidth
                    let end = x + binWidth
                    while x < end {
                        let p = row + x * 4                     // BGRA
                        sum += Int(p[0]) + 2 * Int(p[1]) + Int(p[2])
                        count += 1
                        x += Self.columnStep
                    }
                    data[r * bins + b] = count > 0 ? Float(sum) / Float(count * 4) : 0
                }
            }
        }
        self.rows = rows
        self.pixelWidth = width
        self.pixelHeight = height
        self.data = data
    }
}

enum MotionEstimator {
    enum Result: Equatable {
        case unchanged
        /// 내용이 아래로 `dy` 픽셀 이동 (위로 스크롤하면 양수, 아래로 내리면 음수)
        case scrolled(dy: Int)
        case changed
    }

    /// `region`(픽셀, 왼쪽 위 기준) 안에서 이전 프레임 대비 어떻게 바뀌었는지 판단합니다.
    /// - hint: 직전 프레임의 이동량(행 단위). 스크롤은 보통 비슷한 속도로 이어져서, 그 근처를 먼저 보면
    ///   좋은 후보를 일찍 찾고 나머지 후보는 대부분 계산 도중에 탈락해요.
    static func estimate(previous: RowProfile, current: RowProfile, region: CGRect, hint: Int? = nil) -> Result {
        guard previous.rows == current.rows, previous.pixelWidth == current.pixelWidth else { return .changed }

        let bins = RowProfile.bins
        let r0 = max(0, Int(region.minY) / RowProfile.rowStep)
        let r1 = min(current.rows, Int(region.maxY.rounded(.up)) / RowProfile.rowStep)
        var b0 = Int((region.minX / current.binWidth).rounded(.up))
        var b1 = Int((region.maxX / current.binWidth).rounded(.down))
        if b1 - b0 < 2 {                                    // 좁은 영역은 걸친 칸까지 사용
            b0 = max(0, Int(region.minX / current.binWidth))
            b1 = min(bins, Int((region.maxX / current.binWidth).rounded(.up)))
        }
        let n = r1 - r0
        guard n > 0, b1 > b0 else { return .unchanged }

        let prev = previous.data, cur = current.data
        let minOverlap = max(20, n * 3 / 10)

        /// 이전 프레임 r행이 현재 프레임 r+d행으로 옮겨갔다고 가정했을 때의 평균 밝기 차이
        /// `limit`보다 나빠지는 게 확실해지면 계산을 멈춰요 (틀린 위치는 금방 차이가 커져서 대부분 일찍 끝나요).
        func score(_ d: Int, limit: Float = .infinity) -> Float {
            let start = max(r0, r0 - d), end = min(r1, r1 - d)
            guard end - start >= minOverlap else { return .infinity }
            let denom = Float((end - start) * (b1 - b0))
            let budget = limit * denom
            var total: Float = 0
            for r in start..<end {
                let p = r * bins, c = (r + d) * bins
                for b in b0..<b1 { total += abs(prev[p + b] - cur[c + b]) }
                if total >= budget { return .infinity }
            }
            return total / denom
        }

        let still = score(0)
        if still < 0.8 { return .unchanged }               // 눈에 띄는 변화 없음 (커서 깜빡임 등)
        guard n >= 40 else { return .changed }              // 너무 작은 영역은 스크롤 판단 안 함

        let maxShift = min(n / 2, 200)                      // 한 프레임에 최대 400픽셀
        var best = (d: 0, s: still)
        if let hint, hint != 0, abs(hint) <= maxShift {
            for d in (hint - 3)...(hint + 3) where d != 0 && abs(d) <= maxShift {
                let s = score(d, limit: best.s)
                if s < best.s { best = (d, s) }
            }
        }
        for d in -maxShift...maxShift where d != 0 {
            let s = score(d, limit: best.s)
            if s < best.s { best = (d, s) }
        }
        if best.d != 0, best.s < still * 0.3, best.s < 5 {
            return .scrolled(dy: best.d * RowProfile.rowStep)
        }
        return .changed
    }
}
