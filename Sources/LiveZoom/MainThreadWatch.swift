import Foundation
import os
import QuartzCore

/// Notices when the main thread stops responding, so input and the cursor fail safe instead of leaving the
/// user with swallowed clicks or no visible cursor: the event taps and this monitor run on other threads.
final class MainThreadWatch {
    static let shared = MainThreadWatch()

    private let lastBeat = OSAllocatedUnfairLock(initialState: CACurrentMediaTime())
    private var heartbeat: Timer?
    private var monitor: DispatchSourceTimer?

    /// True when the main thread has not run for over a second.
    var isStalled: Bool { CACurrentMediaTime() - lastBeat.withLock { $0 } > 1 }

    /// `onStall` runs on a background queue, once per stall.
    func start(onStall: @escaping @Sendable () -> Void) {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.lastBeat.withLock { $0 = CACurrentMediaTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        source.schedule(deadline: .now() + 1, repeating: 0.25)
        var reported = false
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isStalled, !reported {
                reported = true
                onStall()
            } else if !self.isStalled {
                reported = false
            }
        }
        source.resume()
        monitor = source
    }
}
