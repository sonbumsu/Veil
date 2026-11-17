import AppKit
import Observation

/// 실시간 번역 모드를 켜고 끕니다.
@MainActor
@Observable
final class TranslationController {
    private(set) var isLive = false

    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private var capture: LiveCapture?
    @ObservationIgnored private var pipeline: Task<Void, Never>?

    func toggle() {
        if isLive { stop() } else { start() }
    }

    func start() {
        guard !isLive else { return }
        isLive = true

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { isLive = false; return }

        let state = OverlayState()
        overlay.show(state: state, on: screen)

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            state.show([], pending: [], frameIndex: 0, isTranslating: false, notice: "화면 녹화 권한이 필요해요 · 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 켠 뒤 앱 재실행")
            return
        }

        let size = screen.frame.size
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let capture = LiveCapture(
            scale: screen.backingScaleFactor,
            framesPerSecond: screen.maximumFramesPerSecond,
            onScroll: { scroll in
                // 스크롤은 순서가 중요해서 Task 대신 메인 큐에 순서대로 넣어요.
                DispatchQueue.main.async { MainActor.assumeIsolated { state.applyScroll(scroll) } }
            },
            onLostTrack: { region in
                DispatchQueue.main.async { MainActor.assumeIsolated { state.hideBlocks(in: region) } }
            },
            onStop: { [weak self] in Task { @MainActor in self?.stop() } }
        )
        self.capture = capture

        pipeline = Task.detached {
            do {
                try await capture.start(displayID: displayID, pointSize: size)
            } catch {
                await state.show([], pending: [], frameIndex: 0, isTranslating: false, notice: "캡처를 시작하지 못했어요: \(error.localizedDescription)")
                return
            }
            await LivePipeline.run(capture: capture, screenFrame: screenFrame, scale: scale, state: state)
        }
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        pipeline?.cancel()
        pipeline = nil
        if let capture {
            Task { await capture.stop() }
        }
        capture = nil
        overlay.close()
    }
}
