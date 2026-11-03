import Foundation

/// Whether a live SSH session should keep this process scheduled.
///
/// Leaving the foreground suspends the process. The socket then stops
/// answering, and the server drops it. Holding is the decision; on iOS the
/// playback below is what actually keeps the process running, and only while
/// a session is connected. The session itself is not paused: pausing stops
/// the read, the socket fills, and the server drops the client anyway.
enum SessionKeepAlive {
  static func shouldHold(active: Bool, liveSessions: Int) -> Bool {
    !active && liveSessions > 0
  }
}

#if os(iOS)
  import AVFoundation
  import UIKit

  extension SessionKeepAlive {
    /// Starts the silent playback when the scene is no longer in front and a
    /// session is up, and stops it the moment either stops being true.
    @MainActor
    static func sync(active: Bool, liveSessions: Int) {
      if shouldHold(active: active, liveSessions: liveSessions) {
        KeepAliveAudio.shared.start()
      } else {
        KeepAliveAudio.shared.stop()
      }
    }
  }

  /// Silent playback, mixed under whatever else is playing.
  ///
  /// A buffer of zeros is treated as silence and the process is suspended
  /// anyway, so this is a quiet tone at a low volume. The background task is
  /// only the bridge into that playback: audio is what lasts, and the task is
  /// ended once playback has started so the system does not expire it.
  @MainActor
  private final class KeepAliveAudio: NSObject {
    static let shared = KeepAliveAudio()

    private var player: AVAudioPlayer?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var holding = false
    private var armed = false

    private override init() { super.init() }

    func start() {
      arm()
      holding = true
      guard player?.isPlaying != true else { return }
      beginTask()
      startAudio()
      if player?.isPlaying == true { endTask() }
    }

    func stop() {
      holding = false
      player?.stop()
      try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
      endTask()
    }

    private func arm() {
      guard !armed else { return }
      armed = true
      let center = NotificationCenter.default
      center.addObserver(
        self, selector: #selector(interrupted(_:)),
        name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
      center.addObserver(
        self, selector: #selector(audioReset(_:)),
        name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func interrupted(_ note: Notification) {
      guard holding else { return }
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      guard type == .ended else { return }
      let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
      if let options, !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { return }
      startAudio()
    }

    @objc private func audioReset(_ note: Notification) {
      guard holding else { return }
      player?.stop()
      player = nil
      startAudio()
    }

    private func startAudio() {
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
      } catch {
        return
      }
      if player == nil {
        guard let made = try? AVAudioPlayer(data: KeepAliveAudio.tone) else { return }
        made.numberOfLoops = -1
        made.volume = 0.01
        made.prepareToPlay()
        player = made
      }
      player?.play()
    }

    private func beginTask() {
      guard task == .invalid else { return }
      task = UIApplication.shared.beginBackgroundTask(withName: "tether.session") {
        KeepAliveAudio.expire()
      }
    }

    /// The expiration handler is not on this actor. It only ends the task,
    /// and the system delivers it on the main thread.
    nonisolated private static func expire() {
      MainActor.assumeIsolated { shared.endTask() }
    }

    private func endTask() {
      guard task != .invalid else { return }
      let ending = task
      task = .invalid
      UIApplication.shared.endBackgroundTask(ending)
    }

    /// One second of a very quiet 40 Hz tone, 8 kHz 16-bit mono.
    private static let tone: Data = {
      let sampleRate = 8_000
      let samples = sampleRate
      let dataSize = samples * 2
      var data = Data(capacity: 44 + dataSize)
      func bytes(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      func bytes16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      data.append(contentsOf: "RIFF".utf8)
      bytes(UInt32(36 + dataSize))
      data.append(contentsOf: "WAVEfmt ".utf8)
      bytes(16)
      bytes16(1)
      bytes16(1)
      bytes(UInt32(sampleRate))
      bytes(UInt32(sampleRate * 2))
      bytes16(2)
      bytes16(16)
      data.append(contentsOf: "data".utf8)
      bytes(UInt32(dataSize))
      for index in 0..<samples {
        let angle = 2 * Double.pi * 40 * Double(index) / Double(sampleRate)
        bytes16(UInt16(bitPattern: Int16(sin(angle) * 1200)))
      }
      return data
    }()
  }
#endif
