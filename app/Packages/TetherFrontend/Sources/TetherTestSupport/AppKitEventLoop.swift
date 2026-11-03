#if os(macOS)
  import AppKit
  import Testing

  /// AppKit's event loop, running under a test process that touches windows.
  ///
  /// A `swift test` process idles in the run loop of Swift's async `main`,
  /// and when that run loop returns, the process exits 0. Once anything
  /// pulls an AppKit event — a close button's `performClick:`, a control's
  /// mouse tracking — HIToolbox wakes the main thread for every later
  /// window-server event by stopping the main run loop. Without `NSApp.run()`
  /// to absorb it, the stop ends `main`: the run quits with status 0, the
  /// remaining tests and the failures already seen unreported.
  @MainActor
  public enum AppKitEventLoop {
    private static var started = false

    /// Starts `NSApp.run()` on the main thread once per process, and returns
    /// once it is running: a stop queued before then would still reach
    /// `main`'s run loop.
    public static func start() async {
      if !started {
        started = true
        _ = NSApplication.shared
        // A run-loop block, not the main queue: from inside a main-queue
        // block the loop would hold that serial queue, and the main actor's
        // work behind it would never run.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { NSApp.run() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
      }
      while !NSApp.isRunning { await Task.yield() }
    }
  }

  /// One test at a time with the key window, the first responder and the
  /// pasteboard: they belong to the process. A second suite's window made
  /// key ended editing in the first suite's search field, whose test then
  /// failed only when the whole package ran.
  /// Set inside a turn, and inherited by the work under it: a suite nested
  /// in another that declares the trait already holds its parent's turn.
  /// Asking again there waited on itself, and the run hung.
  enum AppKitTurnHolder {
    @TaskLocal static var holding = false
  }

  @MainActor
  enum AppKitTurn {
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
      guard held else {
        held = true
        return
      }
      await withCheckedContinuation { waiting.append($0) }
    }

    /// The turn passes straight to the next waiter, so `held` stays true.
    static func release() {
      if waiting.isEmpty {
        held = false
      } else {
        waiting.removeFirst().resume()
      }
    }
  }

  /// A suite or test that touches windows or pulls AppKit events declares it:
  /// `@Suite(.appKitEventLoop)`. Its tests run under AppKit's event loop, one
  /// at a time across every suite that declares it.
  public struct AppKitEventLoopTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
      for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
      await AppKitEventLoop.start()
      // A suite's own scope holds no turn: its tests each take one. Inside a
      // turn already held — the trait on a parent suite and on this one —
      // the test runs in that turn.
      guard testCase != nil, !AppKitTurnHolder.holding else { return try await function() }
      await AppKitTurn.acquire()
      do {
        try await AppKitTurnHolder.$holding.withValue(true) { try await function() }
      } catch {
        await AppKitTurn.release()
        throw error
      }
      await AppKitTurn.release()
    }
  }

  extension Trait where Self == AppKitEventLoopTrait {
    public static var appKitEventLoop: Self { Self() }
  }
#else
  import Testing

  /// A phone has no AppKit event loop to keep alive. Suites shared with the
  /// Mac declare the trait all the same, so it is here, and does nothing.
  public struct AppKitEventLoopTrait: SuiteTrait, TestTrait {
    public var isRecursive: Bool { true }
  }

  extension Trait where Self == AppKitEventLoopTrait {
    public static var appKitEventLoop: Self { Self() }
  }
#endif
