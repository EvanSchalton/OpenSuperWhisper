import Foundation

/// Pauses/resumes system media playback via the private MediaRemote framework.
///
/// On record-start we first ask MediaRemote whether something is actually playing;
/// we only send a pause (and arm the resume) when it is. On stop we resume only if
/// we paused this cycle. That way media that was already paused/idle — e.g. a
/// YouTube tab you stopped earlier, or a background app macOS keeps alive — is
/// never spuriously started when you finish recording.
///
/// MediaRemote's "now playing" is a single system-wide owner, so this acts on the
/// active player; it can't independently restore several simultaneous sources.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Whether we sent a pause this cycle, so `resumeMedia` only plays what we
    /// paused. Touched only on the main queue (see pause/resume) — no data race.
    private(set) var didPauseMedia = false

    /// Bumped on every pause/resume. Because the "is playing?" query is async, a
    /// resume can arrive before a pause's callback fires (very short recording);
    /// the callback checks this token and no-ops if superseded, so we never send a
    /// pause with no matching resume (which would leave media stuck paused).
    private var cycle = 0

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?
    /// MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, completion(isPlaying)).
    private let getIsPlaying: (@convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void)?

    private init() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
            ),
            let sendPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else {
            sendCommand = nil
            getIsPlaying = nil
            return
        }
        sendCommand = unsafeBitCast(sendPtr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)

        if let isPlayingPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
        ) {
            getIsPlaying = unsafeBitCast(
                isPlayingPtr,
                to: (@convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void).self
            )
        } else {
            getIsPlaying = nil
        }
    }

    /// Pause playback, but only if something is actually playing right now — so we
    /// don't "wake" idle/paused media on resume. The MediaRemote query is async; all
    /// state is marshalled onto the main queue and cycle-guarded so a resume arriving
    /// before this pause resolves can't leave media stuck paused.
    func pauseMedia() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sendCommand = self.sendCommand else { return }
            self.cycle += 1
            let cycle = self.cycle

            guard let getIsPlaying = self.getIsPlaying else {
                // Read API unavailable (framework changed): fall back to the old
                // always-pause/always-resume behavior so the feature still works.
                self.didPauseMedia = sendCommand(Self.kMRPause, nil)
                return
            }

            getIsPlaying(DispatchQueue.main) { [weak self] isPlaying in
                guard let self, cycle == self.cycle else { return }  // superseded by a resume
                self.didPauseMedia = isPlaying ? sendCommand(Self.kMRPause, nil) : false
            }
        }
    }

    /// Sends play, but only if we actually paused something this cycle. Bumps the
    /// cycle first so an in-flight pause query (not yet resolved) becomes a no-op.
    func resumeMedia() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cycle += 1
            guard self.didPauseMedia, let sendCommand = self.sendCommand else { return }
            _ = sendCommand(Self.kMRPlay, nil)
            self.didPauseMedia = false
        }
    }
}
