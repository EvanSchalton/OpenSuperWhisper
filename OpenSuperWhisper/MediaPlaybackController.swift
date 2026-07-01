import Foundation

/// Pauses/resumes system media playback via the private MediaRemote framework.
///
/// The pause is sent **unconditionally** — deliberately NOT probing "is something
/// playing?" synchronously at record-start. The moment recording starts, the audio-session
/// setup (switching the default input + starting `AVAudioRecorder`) transiently clears the
/// system Now Playing `playing` flag, so a probe there falsely reports not-playing and the
/// pause gets skipped — the #126 regression (browser tabs like YouTube in Chrome never
/// paused). A pause command is a harmless no-op when nothing is playing, so sending it
/// unconditionally is both correct and reliable.
///
/// To still avoid *waking* idle/already-paused media on resume, we gate the resume on a
/// cached "is Now Playing playing?" value maintained from MediaRemote notifications — read
/// synchronously at pause time, *before* the audio setup disrupts the flag. When the
/// notification API is unavailable the cache stays `true`, degrading to the reliable
/// #126 behavior (always pause, always resume) rather than silently doing nothing.
///
/// MediaRemote's "now playing" is a single system-wide owner, so this acts on the active
/// player; it can't independently restore several simultaneous sources.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Whether we armed a resume this cycle (something was playing when we paused).
    private(set) var didPauseMedia = false

    /// Live "is the Now Playing app playing?", updated from MediaRemote notifications so it
    /// can be read synchronously at pause time (before the audio session clears the flag).
    /// Defaults to `true`: if notifications never arrive we still pause+resume (#126) instead
    /// of missing the pause. Only a real not-playing notification flips it false, so we never
    /// leave genuinely-playing media stuck paused.
    private var isNowPlaying = true

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?

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
        registerForNowPlayingUpdates(bundle: bundle)
    }

    /// Subscribe to MediaRemote's "is playing" notifications so `isNowPlaying` reflects the
    /// real state without a synchronous probe. Best-effort: if the symbols aren't present the
    /// cache stays `true` and we fall back to unconditional pause+resume.
    private func registerForNowPlayingUpdates(bundle: CFBundle?) {
        guard let bundle,
              let regPtr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString)
        else { return }

        typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
        let register = unsafeBitCast(regPtr, to: RegisterFn.self)
        register(DispatchQueue.main)

        NotificationCenter.default.addObserver(
            forName: Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let playing = note.userInfo?["kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"] as? Bool
            else { return }
            self?.isNowPlaying = playing
        }
    }

    /// Pause playback (unconditional = reliable), arming a resume only if something was
    /// actually playing when we paused.
    func pauseMedia() {
        guard let sendCommand else { return }
        let wasPlaying = isNowPlaying  // snapshot before the audio session disrupts the flag
        _ = sendCommand(Self.kMRPause, nil)
        didPauseMedia = wasPlaying
    }

    /// Resume playback, but only if we paused something this cycle.
    func resumeMedia() {
        guard didPauseMedia, let sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
