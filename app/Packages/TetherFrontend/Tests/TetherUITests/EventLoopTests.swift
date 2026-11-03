#if os(macOS)
  import AppKit
  import Testing
  import TetherTestSupport

  /// What HIToolbox does for every window-server event once anything has
  /// pulled one: it stops the main run loop to wake the event wait. Under a
  /// test process that stop used to end `main`, exiting 0 mid-run. If it
  /// still did, this run would end without its summary, and the commit gate
  /// refuses a run that does not report.
  @MainActor
  @Suite("AppKit event loop", .appKitEventLoop)
  struct EventLoopTests {
    @Test("a stop meant for AppKit's event wait does not end the test run")
    func stopDoesNotEndTheRun() async throws {
      for _ in 0..<3 {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
          CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(NSApp.isRunning)
    }
  }
#endif

#if os(macOS)
  /// The trait on a suite and on a suite inside it: one turn, not two.
  /// Taking it twice waited on itself, and the whole run hung.
  @MainActor
  @Suite("AppKit turn, nested", .appKitEventLoop)
  struct NestedTurnTests {
    @Suite("inner", .appKitEventLoop)
    struct Inner {
      @Test("a test under two declarations runs")
      func runs() { #expect(Bool(true)) }
    }
  }
#endif
