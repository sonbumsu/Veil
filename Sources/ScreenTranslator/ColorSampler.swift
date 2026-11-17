import CoreVideo
import SwiftUI

struct RGB: Sendable, Equatable {
    var r: Double, g: Double, b: Double

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    func distance(to o: RGB) -> Double {
        ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() / 3.0.squareRoot()
    }
}

/// 원문 주변의 배경색과 글자색을 화면에서 뽑아요.
/// 번역 상자를 그 색으로 칠하면 원래 화면에 자연스럽게 녹아들어요.
enum ColorSampler {
    static func apply(to paragraphs: inout [Paragraph], pixelBuffer: CVPixelBuffer, scale: CGFloat) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        func pixel(_ x: Int, _ y: Int) -> RGB {
            let p = base + min(max(y, 0), height - 1) * bytesPerRow + min(max(x, 0), width - 1) * 4   // BGRA
            return RGB(r: Double(p[2]) / 255, g: Double(p[1]) / 255, b: Double(p[0]) / 255)
        }

        for i in paragraphs.indices {
            let r = paragraphs[i].rect
            let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)

            // 1) 배경색: 글자 바로 바깥 테두리를 한 바퀴 돌며 샘플 → 중앙값 (주변에 다른 글이 있어도 강함)
            let ring = px.insetBy(dx: -3 * scale, dy: -3 * scale)
            let step = max(2, Int(scale * 3))
            var edge: [RGB] = []
            for x in stride(from: Int(ring.minX), to: Int(ring.maxX), by: step) {
                edge.append(pixel(x, Int(ring.minY)))
                edge.append(pixel(x, Int(ring.maxY) - 1))
            }
            for y in stride(from: Int(ring.minY), to: Int(ring.maxY), by: step) {
                edge.append(pixel(Int(ring.minX), y))
                edge.append(pixel(Int(ring.maxX) - 1, y))
            }
            guard !edge.isEmpty else { continue }
            let background = median(edge)

            // 2) 글자색: 안쪽에서 배경과 가장 다른 픽셀들의 평균 (테두리 흐림 픽셀은 제외됨)
            let s = max(1, Int((px.width * px.height / 3000).squareRoot()))   // 최대 약 3000개 샘플
            var inside: [(distance: Double, color: RGB)] = []
            for y in stride(from: Int(px.minY), to: Int(px.maxY), by: s) {
                for x in stride(from: Int(px.minX), to: Int(px.maxX), by: s) {
                    let c = pixel(x, y)
                    inside.append((c.distance(to: background), c))
                }
            }
            inside.sort { $0.distance > $1.distance }
            let strongest = inside.prefix(max(1, inside.count / 12))
            var foreground = average(strongest.map(\.color))
            if foreground.distance(to: background) < 0.25 {           // 대비가 약하면 읽기 좋은 흑/백으로
                foreground = background.luminance > 0.5 ? .black : .white
            }

            paragraphs[i].background = background
            paragraphs[i].foreground = foreground

            // 3) 글자만 지운 배경 그림
            let area = BlockGeometry.patchRect(for: r, fontSize: paragraphs[i].fontSize, isVertical: paragraphs[i].isVertical)
            paragraphs[i].patch = BackgroundPatch.make(
                area: CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale),
                background: background, foreground: foreground, scale: scale, pixel: pixel)
        }
    }

    private static func median(_ colors: [RGB]) -> RGB {
        func mid(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        return RGB(r: mid(colors.map(\.r)), g: mid(colors.map(\.g)), b: mid(colors.map(\.b)))
    }

    private static func average(_ colors: [RGB]) -> RGB {
        let n = Double(max(colors.count, 1))
        return RGB(r: colors.map(\.r).reduce(0, +) / n,
                   g: colors.map(\.g).reduce(0, +) / n,
                   b: colors.map(\.b).reduce(0, +) / n)
    }
}
