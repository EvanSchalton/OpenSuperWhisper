import Foundation

/// Pauses/resumes system media playback via the private MediaRemote framework.
///
/// The pause is sent **unconditionally** — a synchronous "is something playing?" probe at
/// record-start reads false, because starting `AVAudioRecorder` transiently clears the system
/// Now Playing `playing` flag (#126), so a probe there wrongly skips the pause (browser tabs
/// like YouTube in Chrome never paused). A pause command is a harmless no-op when nothing plays,
/// so sending it unconditionally is both correct and reliable.
///
/// To still avoid *waking* idle/already-paused media on resume, we resume only if something was
/// actually playing when we paused. We can't probe that reliably at record-start (the disruption
/// above), so instead a lightweight timer **polls** `MRMediaRemoteGetNowPlayingApplicationIsPlaying`
/// while we're NOT recording and caches the result. `pauseMedia` reads that pre-recording snapshot
/// and freezes it (stops the poll) for the duration of the recording. The probe is only unreliable
/// *during* record-start; polled at idle it accurately reflects whether media is playing.
///
/// If the read API is unavailable we default the cache to "playing", so we still pause+resume
/// (the reliable #126 behavior) instead of silently doing nothing. MediaRemote's now-playing is a
/// single system-wide owner, so this acts on the active player; it can't restore several sources.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Whether we armed a resume this cycle (something was playing when we paused).
    private(set) var didPauseMedia = false

    /// Cached "is the Now Playing app playing?", refreshed by `pollTimer` while not recording, so
    /// it reflects the state from *before* a recording disrupts the flag.
    private var isNowPlaying: Bool

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1
    private static let pollInterval: TimeInterval = 1.0

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?
    /// MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, completion(isPlaying)).
    private let getIsPlaying: (@convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void)?
    private var pollTimer: Timer?

    private init() {
        let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        )
        if let bundle,
           let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)
        } else {
            sendCommand = nil
        }
        if let bundle,
           let ptr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            getIsPlaying = unsafeBitCast(
                ptr, to: (@convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void).self)
        } else {
            getIsPlaying = nil
        }

        // CRITICAL: prime the now-playing connection. Without registering, the IsPlaying probe
        // reports not-playing for browser media (a Chrome/YouTube tab) even when it's clearly
        // playing — so the resume was never armed and media never restarted. Registering makes
        // the probe accurate (verified: reports IsPlaying=true, rate=1 for a playing Chrome tab).
        if let bundle,
           let regPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
            unsafeBitCast(regPtr, to: RegisterFn.self)(DispatchQueue.main)
        }

        // No read API → assume playing so we still pause+resume (#126 fallback) rather than nothing.
        isNowPlaying = (getIsPlaying == nil)
        startPolling()
    }

    /// Poll the playing state while not recording (fires in `.common` mode so it keeps ticking
    /// during menu tracking / window resizing).
    private func startPolling() {
        guard getIsPlaying != nil, pollTimer == nil else { return }
        refreshNowPlaying()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshNowPlaying() {
        getIsPlaying?(DispatchQueue.main) { [weak self] playing in
            self?.isNowPlaying = playing
        }
    }

    /// Pause playback (unconditional = reliable), arming a resume only if something was actually
    /// playing when we paused, and freezing the cache while the recording runs.
    func pauseMedia() {
        guard let sendCommand else { return }
        let wasPlaying = isNowPlaying   // pre-recording snapshot, before the audio session disrupts it
        stopPolling()
        _ = sendCommand(Self.kMRPause, nil)
        didPauseMedia = wasPlaying
    }

    /// Resume playback, but only if we paused something this cycle; then re-arm the poll.
    func resumeMedia() {
        defer { startPolling() }
        guard didPauseMedia, let sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
