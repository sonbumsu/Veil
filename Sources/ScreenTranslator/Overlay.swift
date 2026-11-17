import AppKit
import SwiftUI

@MainActor
@Observable
final class OverlayState {
    /// 번역 블록들. 스크롤마다 바뀌어서 SwiftUI 관찰 대상에서 빼고, 레이어 화면(BlockLayerView)에 직접 알려요.
    @ObservationIgnored private(set) var blocks: [TranslatedBlock] = [] {
        didSet { onBlocksChange?(blocks) }
    }
    @ObservationIgnored var onBlocksChange: (([TranslatedBlock]) -> Void)?
    private(set) var notice: String?
    private(set) var isTranslating = false
    /// ⌥(Option)를 누르고 있는 동안 원문 보기
    var isPeeking = false

    /// 최근 스크롤 기록. 글자 인식은 0.5초쯤 걸려서, 결과가 나왔을 땐 이미 화면이 더 움직였을 수 있어요.
    /// 인식한 프레임 이후의 스크롤을 결과에 다시 적용해서 위치를 맞춰요.
    @ObservationIgnored private var scrollLog: [LiveCapture.Scroll] = []

    /// 스크롤이 감지되면 해당 영역의 번역을 같은 만큼 바로 옮겨요.
    func applyScroll(_ scroll: LiveCapture.Scroll) {
        scrollLog.append(scroll)
        if scrollLog.count > 600 { scrollLog.removeFirst(300) }
        blocks = blocks.map { Self.shifted($0, by: scroll) }
    }

    /// 스크롤을 놓친 영역의 번역은 엉뚱한 자리에 멈춰 있지 않게 숨겨요.
    func hideBlocks(in region: CGRect) {
        guard blocks.contains(where: { !$0.isHidden && region.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }) else { return }
        blocks = blocks.map { block in
            var block = block
            if region.contains(CGPoint(x: block.rect.midX, y: block.rect.midY)) { block.isHidden = true }
            return block
        }
    }

    /// - blocks: `frameIndex` 프레임 기준 위치의 번역들
    /// - pending: 번역을 기다리는 문단 위치. 여기에 걸친 기존 번역은 새 번역이 올 때까지 유지해요.
    func show(_ newBlocks: [TranslatedBlock], pending: [CGRect], frameIndex: Int,
              isTranslating: Bool = false, notice: String?) {
        scrollLog.removeAll { $0.frameIndex <= frameIndex }

        var fresh = newBlocks
        var pending = pending
        for scroll in scrollLog {
            fresh = fresh.map { Self.shifted($0, by: scroll) }
            pending = pending.map { Self.shifted($0, by: scroll) }
        }

        // 인식 위치가 1~2pt씩 흔들려도 번역이 떨리지 않게, 같은 블록이 거의 같은 자리면 기존 위치를 유지해요.
        let previous = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        fresh = fresh.map { block in
            guard let old = previous[block.id], !old.isHidden, Self.isNearlySame(old.rect, block.rect) else { return block }
            var block = block
            block.rect = old.rect
            block.patch = old.patch ?? block.patch
            return block
        }
        // 그 자리에 원래 번역이 없던 블록만 살짝 나타나게 (바뀌는 건 바로 교체)
        fresh = fresh.map { block in
            var block = block
            block.fadesIn = previous[block.id] == nil && !blocks.contains { $0.rect.intersects(block.rect) }
            return block
        }

        // 새 번역을 기다리는 자리의 기존 번역은 남겨둬요. 새 번역이 대부분을 덮을 때만 지워요.
        let freshIDs = Set(fresh.map(\.id))
        let kept = blocks.filter { old in
            !old.isHidden                                   // 위치를 놓친 번역은 남기지 않아요
                && !freshIDs.contains(old.id)
                && pending.contains { $0.intersects(old.rect) }
                && !fresh.contains { Self.coverage(of: old.rect, by: $0.rect) > 0.6 }
        }
        blocks = kept + fresh   // 새 번역이 위에 그려지게
        self.notice = notice
        self.isTranslating = isTranslating
    }

    private static func isNearlySame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.maxX - b.maxX) < 3 && abs(a.maxY - b.maxY) < 3
    }

    /// `rect` 넓이 중 `other`가 덮는 비율
    private static func coverage(of rect: CGRect, by other: CGRect) -> CGFloat {
        let overlap = rect.intersection(other)
        guard !overlap.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (rect.width * rect.height)
    }

    private static func shifted(_ block: TranslatedBlock, by scroll: LiveCapture.Scroll) -> TranslatedBlock {
        var block = block
        block.rect = shifted(block.rect, by: scroll)
        return block
    }

    private static func shifted(_ rect: CGRect, by scroll: LiveCapture.Scroll) -> CGRect {
        scroll.region.contains(CGPoint(x: rect.midX, y: rect.midY)) ? rect.offsetBy(dx: 0, dy: scroll.dy) : rect
    }
}

/// 화면 전체를 덮는 투명 창. 마우스 입력은 모두 아래 앱으로 통과시켜서 스크롤·클릭이 그대로 돼요.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var peekTimer: Timer?

    func show(state: OverlayState, on screen: NSScreen) {
        close()

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none   // 화면 캡처에 번역 창이 찍히지 않게 (자기 번역을 다시 읽는 깜빡임 방지)

        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let container = NSView(frame: bounds)
        // 번역 블록: 미리 그려둔 그림을 Core Animation 레이어로 옮기기만 해서 스크롤을 부드럽게 따라가요.
        let blockView = BlockLayerView(frame: bounds, scale: screen.backingScaleFactor)
        blockView.autoresizingMask = [.width, .height]
        // 상태 표시: SwiftUI
        let badge = NSHostingView(rootView: StatusOverlay(state: state))
        badge.sizingOptions = []
        badge.frame = bounds
        badge.autoresizingMask = [.width, .height]
        container.addSubview(blockView)
        container.addSubview(badge)

        panel.contentView = container
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        state.onBlocksChange = { [weak blockView] blocks in blockView?.update(blocks) }
        blockView.update(state.blocks)

        // ⌥만 누르고 있으면 원문 보기 (권한 없이 현재 키 상태를 확인)
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak blockView] _ in
            let peeking = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            MainActor.assumeIsolated {
                guard state.isPeeking != peeking else { return }   // 같은 값이면 다시 그리지 않게
                state.isPeeking = peeking
                blockView?.setPeeking(peeking)
            }
        }
    }

    func close() {
        peekTimer?.invalidate()
        peekTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 번역 블록들을 Core Animation 레이어로 그려요.
///  - 블록 내용(배경 덮개 + 번역문)은 바뀔 때만 그림으로 한 번 그려요.
///  - 스크롤할 땐 레이어 위치만 바꿔서, 화면 합성기가 바로 옮겨요 (다시 그리기·레이아웃 없음).
@MainActor
final class BlockLayerView: NSView {
    private let scale: CGFloat
    private let root = CALayer()
    private var layers: [String: CALayer] = [:]
    private var signatures: [String: String] = [:]
    private var hiddenIDs: Set<String> = []

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        layer = CALayer()          // 레이어 호스팅 뷰
        wantsLayer = true
        root.frame = bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer!.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPeeking(_ peeking: Bool) {
        fade(root, to: peeking ? 0 : 1, duration: 0.1)
    }

    func update(_ blocks: [TranslatedBlock]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 위치 변경에 기본 애니메이션이 붙으면 오히려 늦게 따라가요
        defer { CATransaction.commit() }

        var alive: Set<String> = []
        for (index, block) in blocks.enumerated() {
            alive.insert(block.id)
            let area = BlockGeometry.patchRect(for: block.rect, fontSize: block.fontSize, isVertical: block.isVertical)
            // AppKit 좌표는 아래가 0
            let frame = CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)

            let layer: CALayer
            if let existing = layers[block.id] {
                layer = existing
            } else {
                layer = CALayer()
                layer.contentsScale = scale
                layer.contentsGravity = .resize
                root.addSublayer(layer)
                layers[block.id] = layer
                if block.fadesIn && !block.isHidden {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0
                    animation.toValue = 1
                    animation.duration = 0.15
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(animation, forKey: "fadeIn")
                }
            }
            layer.frame = frame
            layer.zPosition = CGFloat(index)

            let signature = Self.signature(of: block, size: area.size)
            if signatures[block.id] != signature {
                signatures[block.id] = signature
                layer.contents = render(block, size: area.size)
            }

            let wasHidden = hiddenIDs.contains(block.id)
            if block.isHidden != wasHidden {
                if block.isHidden { hiddenIDs.insert(block.id) } else { hiddenIDs.remove(block.id) }
                fade(layer, to: block.isHidden ? 0 : 1, duration: 0.12)
            } else {
                layer.opacity = block.isHidden ? 0 : 1
            }
        }

        for (id, layer) in layers where !alive.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
            signatures[id] = nil
            hiddenIDs.remove(id)
        }
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "fade")
    }

    private static func signature(of block: TranslatedBlock, size: CGSize) -> String {
        let patch = block.patch.map { "\(ObjectIdentifier($0.image).hashValue)" } ?? "-"
        return "\(block.translated)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))|\(block.fontSize)|"
            + "\(String(describing: block.background))|\(String(describing: block.foreground))|\(patch)"
    }

    private func render(_ block: TranslatedBlock, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: BlockContentView(block: block).frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// 블록 하나의 모습: 원문을 가리는 덮개 + 번역문. (그림으로 한 번 그려서 레이어에 올려요)
/// 원문의 배경을 깔고 원문의 글자색으로 써서, 원래 화면에 쓰여 있던 것처럼 보이게 해요.
private struct BlockContentView: View {
    let block: TranslatedBlock

    var body: some View {
        let box = BlockGeometry.textRect(for: block.rect, fontSize: block.fontSize, isVertical: block.isVertical)
        let margin = BlockGeometry.margin
        let foreground = block.foreground?.color ?? .primary

        Text(block.translated)
            .font(.system(size: max(block.fontSize, 9)))
            .foregroundStyle(foreground)
            .multilineTextAlignment(block.isVertical ? .center : .leading)
            .minimumScaleFactor(0.35)
            .padding(.horizontal, 2)
            .frame(width: box.width, height: box.height, alignment: block.isVertical ? .top : .topLeading)
            .padding(margin)
            .background { cover }
    }

    /// 원문을 가리는 덮개. 글자만 지운 배경 그림이 있으면 그걸, 없으면 배경색을 써요.
    /// 가장자리를 살짝 흐리게 해서 경계가 칼같이 보이지 않게 해요.
    @ViewBuilder
    private var cover: some View {
        let feather = RoundedRectangle(cornerRadius: 4).padding(1.5).blur(radius: 1.5)
        if let patch = block.patch {
            Image(decorative: patch.image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .mask(feather)
        } else {
            (block.background?.color ?? Color(nsColor: .textBackgroundColor))
                .mask(feather)
        }
    }
}

/// 오른쪽 위의 작은 상태 표시 (원문 보기 중엔 숨김)
private struct StatusOverlay: View {
    let state: OverlayState

    var body: some View {
        StatusBadge(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(state.isPeeking ? 0 : 1)
            .animation(.easeOut(duration: 0.1), value: state.isPeeking)
            .ignoresSafeArea()
    }
}

/// 오른쪽 위의 작은 상태 표시
private struct StatusBadge: View {
    let state: OverlayState

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                if state.isTranslating {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text("실시간 번역").font(.caption.weight(.semibold))
            }
            Text("⌃⌥T 끄기 · ⌥ 누르면 원문").font(.caption2).foregroundStyle(.secondary)
            if let notice = state.notice {
                Text(notice).font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 40)
        .padding(.trailing, 14)
    }
}
