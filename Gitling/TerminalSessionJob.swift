import Foundation
import GitlingIsh

/// The worker owns this job, never the view model. Removing a repository's
/// navigation scope can therefore deinit its owner and cancel the complete tree.
final class TerminalSessionJob: @unchecked Sendable {
    let token = UInt64.random(in: 1...UInt64.max)
    private let lock = NSLock()
    private var cancelled = false
    private var desiredSuspension = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true; lock.unlock()
        gp_ish_cancel(token)
    }
    func suspend(_ paused: Bool) {
        lock.lock(); desiredSuspension = paused; lock.unlock()
        gp_ish_set_suspended(token, paused ? 1 : 0)
    }
    private func applySuspension() {
        lock.lock(); let paused = desiredSuspension; lock.unlock()
        gp_ish_set_suspended(token, paused ? 1 : 0)
    }
    func run(repo: URL, rows: Int, cols: Int, output: @escaping (Data) -> Void,
             suspension: @escaping (Bool) -> Void, completion: @escaping (Result<Int32, Error>?) -> Void) {
        TerminalRuntime.worker.async { [self] in
            // A previous repository may still be reaping its tasks. Wait on
            // this worker, preserving ordering, without retaining the old UI.
            guard !isCancelled else { completion(nil); return }
            guard TerminalRuntime.claim(token) else {
                completion(.failure(WorkingTreeError.busy)); return
            }
            defer { TerminalRuntime.release(token) }
            var result: Result<Int32, Error>?
            do {
                while !isCancelled {
                    do {
                        applySuspension()
                        let code = try TerminalRuntime.shell(repo: repo, token: token, rows: rows, cols: cols,
                            suspension: suspension, output: output)
                        result = isCancelled ? nil : .success(code)
                        break
                    } catch WorkingTreeError.busy {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            } catch {
                result = isCancelled && (error as? TerminalRuntime.Failure)?.retainLease != true ? nil : .failure(error)
            }
            completion(result)
        }
    }
}
