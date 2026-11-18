import AppKit

/// 메뉴바 아이콘: 로고의 "A→가" 말풍선.
/// 템플릿 이미지라서 메뉴바 색(밝은/어두운 모드)에 맞춰 자동으로 칠해져요. 켜져 있으면 속이 찬 말풍선.
@MainActor
enum MenuBarIcon {
    static let off = make(filled: false)
    static let on = make(filled: true)

    private static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.set()

            let bubble = bubblePath(left: 1.5, top: 1.5, right: 20.5, bottom: 14, radius: 4)
            if filled {
                bubble.fill()
                ctx.setBlendMode(.destinationOut)   // 글자를 뚫어서 보이게
            } else {
                bubble.lineWidth = 1.4
                bubble.lineJoinStyle = .round
                bubble.stroke()
            }

            // 화살표 (A 위에서 가 쪽으로)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 6.2, y: 4.5))
            arrow.line(to: NSPoint(x: 15.6, y: 4.5))
            arrow.move(to: NSPoint(x: 13.9, y: 3.2))
            arrow.line(to: NSPoint(x: 15.6, y: 4.5))
            arrow.line(to: NSPoint(x: 13.9, y: 5.8))
            arrow.lineWidth = 1.1
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()

            // 글자는 기준선(baseline)으로 맞춰요 (줄 높이로 가운데 맞추면 아래로 처져요)
            let font = NSFont.systemFont(ofSize: 7, weight: .bold)
            let text = NSAttributedString(string: "A가", attributes: [.font: font, .foregroundColor: NSColor.black])
            let baseline: CGFloat = 11.9
            text.draw(at: NSPoint(x: 11 - text.size().width / 2, y: baseline - font.ascender))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "베일"
        return image
    }

    /// 둥근 사각형 + 왼쪽 아래 꼬리를 한 번에 그린 테두리
    private static func bubblePath(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat, radius r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: left + r, y: top))
        p.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right, y: bottom), radius: r)
        p.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: left, y: bottom), radius: r)
        p.line(to: NSPoint(x: left + 8, y: bottom))
        p.line(to: NSPoint(x: left + 2.5, y: bottom + 3.5))   // 꼬리 끝
        p.line(to: NSPoint(x: left + 4, y: bottom))
        p.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: top), radius: r)
        p.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: right, y: top), radius: r)
        p.close()
        return p
    }
}
