import CoreGraphics
import Foundation
import simd

/// 원문 자리에서 글자 픽셀만 지우고 주변 배경으로 메운 그림.
/// 단색 상자 대신 이걸 깔면 그라데이션·사진·만화 배경 위에서도 글자만 지운 것처럼 보여요.
struct BackgroundPatch: @unchecked Sendable {   // CGImage는 만든 뒤 바뀌지 않아요
    let image: CGImage
}

enum BlockGeometry {
    /// 덮개를 원문보다 이만큼 더 넓게 그려요 (포인트)
    static let margin: CGFloat = 3

    /// 번역문을 그릴 상자 (원문 위치 기준, 가운데 맞춤).
    /// 세로쓰기 원문은 열이 좁아서, 한국어를 가로로 읽을 수 있게 넓혀요.
    static func textRect(for rect: CGRect, fontSize: CGFloat, isVertical: Bool) -> CGRect {
        let width = isVertical ? max(rect.width, fontSize * 5) : rect.width + 6
        let height = rect.height + 4
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// 배경 덮개가 차지하는 영역
    static func patchRect(for rect: CGRect, fontSize: CGFloat, isVertical: Bool) -> CGRect {
        textRect(for: rect, fontSize: fontSize, isVertical: isVertical).insetBy(dx: -margin, dy: -margin)
    }
}

extension BackgroundPatch {
    /// - area: 픽셀 좌표 (왼쪽 위 기준)
    /// - pixel: 화면 픽셀을 읽는 함수 (BGRA 버퍼)
    static func make(area: CGRect, background: RGB, foreground: RGB, scale: CGFloat,
                     pixel: (Int, Int) -> RGB) -> BackgroundPatch? {
        // 배경은 부드러워서 해상도를 낮춰도 티가 안 나요. 최대 약 6만 칸.
        let step = max(Int(scale), Int((area.width * area.height / 60_000).squareRoot().rounded(.up)), 1)
        let w = Int(area.width) / step, h = Int(area.height) / step
        guard w >= 2, h >= 2 else { return nil }

        // 1) 배경과 다른 픽셀(= 글자)을 구멍으로 표시
        let threshold = max(0.12, foreground.distance(to: background) * 0.35)
        var colors = [SIMD3<Float>](repeating: .zero, count: w * h)
        var known = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = pixel(Int(area.minX) + x * step + step / 2, Int(area.minY) + y * step + step / 2)
                colors[y * w + x] = SIMD3(Float(c.r), Float(c.g), Float(c.b))
                known[y * w + x] = c.distance(to: background) < threshold
            }
        }
        // 글자 테두리의 흐린 픽셀까지 지우려고 구멍을 한 칸 넓혀요.
        var grown = known
        for y in 0..<h {
            for x in 0..<w where !known[y * w + x] {
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) { grown[ny * w + nx] = false }
                }
            }
        }
        known = grown
        guard known.lazy.filter({ $0 }).count >= w * h / 10 else { return nil }   // 배경이 거의 안 보이면 단색으로

        // 2) 구멍을 주변 배경으로 메우기 (push-pull: 점점 작게 줄여 평균 낸 뒤 다시 키우며 채움)
        let bg = SIMD3(Float(background.r), Float(background.g), Float(background.b))
        let filled = pushPull(colors: colors, known: known, width: w, height: h, fallback: bg)

        // 3) 이미지로
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = simd_clamp(filled[i], .zero, SIMD3(repeating: 1)) * 255
            bytes[i * 4] = UInt8(c.x.rounded())
            bytes[i * 4 + 1] = UInt8(c.y.rounded())
            bytes[i * 4 + 2] = UInt8(c.z.rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return BackgroundPatch(image: image)
    }

    private struct Level {
        let width: Int, height: Int
        var color: [SIMD3<Float>]   // 가중치가 곱해진 색
        var weight: [Float]         // 0 = 모름, 1 = 확실
    }

    static func pushPull(colors: [SIMD3<Float>], known: [Bool], width: Int, height: Int,
                         fallback: SIMD3<Float>) -> [SIMD3<Float>] {
        var levels = [Level(width: width, height: height,
                            color: zip(colors, known).map { $1 ? $0 : .zero },
                            weight: known.map { $0 ? 1 : 0 })]

        // pull: 2배씩 줄이며 아는 픽셀의 평균
        while levels.last!.width > 1 || levels.last!.height > 1 {
            let f = levels.last!
            let w = (f.width + 1) / 2, h = (f.height + 1) / 2
            var c = [SIMD3<Float>](repeating: .zero, count: w * h)
            var wt = [Float](repeating: 0, count: w * h)
            for y in 0..<f.height {
                for x in 0..<f.width {
                    let i = (y / 2) * w + x / 2
                    c[i] += f.color[y * f.width + x]
                    wt[i] += f.weight[y * f.width + x]
                }
            }
            for i in 0..<(w * h) where wt[i] > 0 {
                let capped = min(wt[i], 1)
                c[i] = c[i] / wt[i] * capped
                wt[i] = capped
            }
            levels.append(Level(width: w, height: h, color: c, weight: wt))
        }

        // 가장 작은 단계도 비어 있으면 배경색으로
        var top = levels[levels.count - 1]
        top.color[0] += (1 - top.weight[0]) * fallback
        top.weight[0] = 1
        levels[levels.count - 1] = top

        // push: 큰 단계로 돌아오며 모르는 부분을 작은 단계 색(부드럽게 보간)으로 채움
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            var fine = levels[l]
            for y in 0..<fine.height {
                for x in 0..<fine.width {
                    let i = y * fine.width + x
                    guard fine.weight[i] < 1 else { continue }
                    let fill = bilinear(coarse, x: (Float(x) + 0.5) / 2 - 0.5, y: (Float(y) + 0.5) / 2 - 0.5)
                    fine.color[i] += (1 - fine.weight[i]) * fill
                    fine.weight[i] = 1
                }
            }
            levels[l] = fine
        }
        return levels[0].color
    }

    private static func bilinear(_ level: Level, x: Float, y: Float) -> SIMD3<Float> {
        let cx = min(max(x, 0), Float(level.width - 1)), cy = min(max(y, 0), Float(level.height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, level.width - 1), y1 = min(y0 + 1, level.height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { level.color[y * level.width + x] }   // push 후엔 가중치 1
        let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
        let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}
