import ScreenCaptureKit
import os

/// 화면 한 프레임. SCStream이 넘겨준 버퍼를 처리 루프로 전달하기 위한 포장.
struct ScreenFrame: @unchecked Sendable {
    let index: Int
    let pixelBuffer: CVPixelBuffer
    /// 이전에 넘긴 프레임 이후의 스크롤들 (순서대로)
    var scrolls: [LiveCapture.Scroll] = []
    /// 이전에 넘긴 프레임 이후 새로 그려진 곳 (포인트, 스크롤로 새로 드러난 띠 포함). nil이면 화면 전체.
    var changed: [CGRect]? = nil
}

/// 화면을 계속 캡처합니다.
///  - 스크롤이 감지되면 바로 `onScroll`로 알려줘요 (초당 최대 30번, 번역 위치를 따라 움직이는 데 사용).
///  - 실제로 내용이 바뀐 프레임만 글자 인식용으로 `frames`에 흘려보내요.
///    처리가 밀리면 오래된 프레임은 버리고 가장 최신 하나만 남겨요.
final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "캡처할 화면을 찾지 못했어요." }
    }

    struct Scroll: Sendable {
        let frameIndex: Int
        let region: CGRect   // 화면 포인트, 왼쪽 위 기준
        let dy: CGFloat      // 포인트

        /// 가운데가 스크롤 영역 안에 있는 사각형을 같은 만큼 옮겨요.
        func apply(to rect: CGRect) -> CGRect {
            region.contains(CGPoint(x: rect.midX, y: rect.midY)) ? rect.offsetBy(dx: 0, dy: dy) : rect
        }
    }

    /// 새 프레임이 준비되면 신호가 와요. 받은 쪽은 `takeFrame()`으로 가져가요.
    let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    /// 아직 안 가져간 프레임. 새 프레임이 오면 버리지 않고 스크롤·바뀐 곳 기록을 합쳐요.
    private let mailbox = OSAllocatedUnfairLock<ScreenFrame?>(initialState: nil)
    private let queue = DispatchQueue(label: "Veil.capture", qos: .userInteractive)
    private let scale: CGFloat
    private let onScroll: @Sendable (Scroll) -> Void
    /// 스크롤 중이던 곳인데 이동량을 못 구한 경우 (번역이 엉뚱한 자리에 남지 않게 잠깐 숨겨요)
    private let onLostTrack: @Sendable (CGRect) -> Void
    private var recentScrolls: [(region: CGRect, time: Date)] = []   // capture 큐에서만 접근
    private var lastMotion: (region: CGRect, rows: Int)?                // 직전 스크롤 (다음 추정의 힌트)
    private let framesPerSecond: Int
    private let onStop: @Sendable () -> Void
    private var stream: SCStream?

    // 아래 값들은 capture 큐에서만 접근
    private var previous: RowProfile?
    private var frameIndex = 0
    /// 글자 인식을 기다리는 최신 프레임. 화면이 잠잠해질 때까지 모았다가 한 번만 넘겨요.
    private var pending: ScreenFrame?
    private var pendingScrolls: [Scroll] = []
    private var pendingChanged: [CGRect] = []
    private var lastChange = Date.distantPast
    private var firstChange: Date?
    private var settleCheckScheduled = false

    /// 마지막 변화 후 이만큼 조용하면 인식 (스크롤이 멈춘 뒤)
    private static let settleDelay: TimeInterval = 0.25
    /// 계속 바뀌는 화면(영상 등)이라도 이 간격으로는 인식
    private static let maxWait: TimeInterval = 1.5

    init(scale: CGFloat,
         framesPerSecond: Int,
         onScroll: @escaping @Sendable (Scroll) -> Void,
         onLostTrack: @escaping @Sendable (CGRect) -> Void,
         onStop: @escaping @Sendable () -> Void) {
        self.onLostTrack = onLostTrack
        self.framesPerSecond = min(max(framesPerSecond, 30), 120)
        (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.scale = scale
        self.onScroll = onScroll
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID, pointSize: CGSize) async throws {
        // 번역 오버레이(이 앱)는 캡처에서 빼야 자기 번역을 다시 읽지 않아요.
        // 방금 띄운 오버레이 창이 목록에 늦게 잡힐 수 있어서 잠깐 기다리며 몇 번 다시 확인해요.
        let pid = ProcessInfo.processInfo.processIdentifier
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<10 where !content.windows.contains(where: { $0.owningApplication?.processID == pid }) {
            try await Task.sleep(for: .milliseconds(100))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayNotFound
        }
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))   // 화면 주사율에 맞춰 부드럽게
        config.queueDepth = 5
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB   // 뽑은 배경색을 sRGB로 다시 그리면 화면과 똑같은 색이 돼요

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,      // .idle = 화면 변화 없음
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        frameIndex += 1
        let profile = RowProfile(pixelBuffer)
        defer { previous = profile }

        guard let previous else {                                   // 첫 프레임은 무조건 인식
            deliver(ScreenFrame(index: frameIndex, pixelBuffer: pixelBuffer))
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: profile.pixelWidth, height: profile.pixelHeight)
        var regions = (info[.dirtyRects] as? [NSDictionary] ?? [])
            .compactMap { CGRect(dictionaryRepresentation: $0)?.intersection(bounds) }
            .filter { !$0.isEmpty }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(12)
        if regions.isEmpty { regions = [bounds] }

        var contentChanged = false
        for region in regions {
            let regionPt = CGRect(x: region.minX / scale, y: region.minY / scale,
                                  width: region.width / scale, height: region.height / scale)
            let hint = lastMotion.flatMap { last in
                abs(last.region.minY - region.minY) < 4 && abs(last.region.maxY - region.maxY) < 4
                    && abs(last.region.minX - region.minX) < 4 ? last.rows : nil
            }
            switch MotionEstimator.estimate(previous: previous, current: profile, region: region, hint: hint) {
            case .unchanged:
                continue
            case .scrolled(let dy):
                contentChanged = true
                lastMotion = (region, dy / RowProfile.rowStep)
                let scroll = Scroll(frameIndex: frameIndex, region: regionPt, dy: CGFloat(dy) / scale)
                onScroll(scroll)
                recordScroll(scroll)
                recentScrolls.append((regionPt, Date()))
            case .changed:
                contentChanged = true
                pendingChanged.append(regionPt)
                recentScrolls.removeAll { Date().timeIntervalSince($0.time) > 0.4 }
                if recentScrolls.contains(where: { $0.region.intersects(regionPt) }) {
                    onLostTrack(regionPt)
                }
            }
        }

        // 픽셀이 실제로 바뀌었을 때만 글자 인식 (오버레이가 스스로를 갱신하는 고리 방지).
        // 스크롤·영상처럼 계속 바뀌는 동안 매 프레임 인식하면 발열이 심해서,
        // 화면이 잠잠해질 때까지 기다렸다가 최신 프레임 하나만 인식해요. 스크롤 중 위치는 onScroll이 따라가요.
        if contentChanged {
            let now = Date()
            pending = ScreenFrame(index: frameIndex, pixelBuffer: pixelBuffer)
            lastChange = now
            if firstChange == nil { firstChange = now }
            scheduleSettleCheck(after: Self.settleDelay)
        }
    }

    /// 스크롤을 기록하고, 이미 기록된 바뀐 곳도 같이 옮겨요. 새로 드러난 띠는 바뀐 곳으로 추가해요.
    private func recordScroll(_ scroll: Scroll) {
        pendingScrolls.append(scroll)
        pendingChanged = pendingChanged.map(scroll.apply)
        let r = scroll.region, dy = scroll.dy
        let revealed = dy < 0
            ? CGRect(x: r.minX, y: r.maxY + dy, width: r.width, height: -dy)   // 아래로 내림 → 아래쪽이 새로 보임
            : CGRect(x: r.minX, y: r.minY, width: r.width, height: dy)         // 위로 올림 → 위쪽이 새로 보임
        pendingChanged.append(revealed.intersection(r))
    }

    private func deliver(_ frame: ScreenFrame) {
        mailbox.withLock { waiting in
            guard let old = waiting else { waiting = frame; return }
            var merged = frame
            merged.scrolls = old.scrolls + frame.scrolls
            if let oldChanged = old.changed, let newChanged = frame.changed {
                merged.changed = oldChanged.map { rect in frame.scrolls.reduce(rect) { $1.apply(to: $0) } } + newChanged
            } else {
                merged.changed = nil
            }
            waiting = merged
        }
        continuation.yield()
    }

    func takeFrame() -> ScreenFrame? {
        mailbox.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
    }

    private func scheduleSettleCheck(after delay: TimeInterval) {
        guard !settleCheckScheduled else { return }
        settleCheckScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.settleCheck()
        }
    }

    private func settleCheck() {
        settleCheckScheduled = false
        guard let frame = pending, let first = firstChange else { return }
        let now = Date()
        let quietFor = now.timeIntervalSince(lastChange)
        let waited = now.timeIntervalSince(first)
        if quietFor >= Self.settleDelay || waited >= Self.maxWait {
            var frame = frame
            frame.scrolls = pendingScrolls
            frame.changed = pendingChanged
            pending = nil
            pendingScrolls = []
            pendingChanged = []
            firstChange = nil
            deliver(frame)
        } else {
            scheduleSettleCheck(after: min(Self.settleDelay - quietFor, Self.maxWait - waited))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
        onStop()
    }
}
