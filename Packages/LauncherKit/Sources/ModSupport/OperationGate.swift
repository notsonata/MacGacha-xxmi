// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Synchronization

/// Actor methods are reentrant across awaits. Disk state is the source of truth,
/// so every operation holds this gate to keep read-modify-write sequences serial.
final class OperationGate: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        let immediate = state.withLock { state -> Bool in
            guard !state.locked else { return false }
            state.locked = true
            return true
        }
        if immediate { return }
        await withCheckedContinuation { continuation in
            let resumed = state.withLock { state -> Bool in
                guard !state.locked else {
                    state.waiters.append(continuation)
                    return false
                }
                state.locked = true
                return true
            }
            if resumed { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.locked = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
