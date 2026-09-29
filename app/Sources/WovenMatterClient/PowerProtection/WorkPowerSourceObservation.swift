import Foundation
import IOKit.ps

/// Notifications arrive on the main run loop, including while the display is
/// asleep. Changing power source must not wait for a conversation state change.
@MainActor
final class WorkPowerSourceObservation {
    private var source: CFRunLoopSource?
    private var fallback: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<WorkPowerSourceObservation>.fromOpaque(context)
                    .takeUnretainedValue().onChange()
            }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            fallback = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    self.onChange()
                }
            }
        }
    }

    isolated deinit {
        fallback?.cancel()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }
}
