#if os(Linux)
import Glibc
import Testing

/// The Linux test runner ignores SIGPIPE from its start (`LinuxTestProcess`), as
/// Linux hosts do: a write to a pipe whose reader is gone fails with EPIPE
/// instead of killing every test in this runner.
@Suite("Broken pipes on Linux")
struct BrokenPipeTests {
    @Test func aWriteToAClosedPipeFailsInsteadOfKillingTheRunner() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        var byte: UInt8 = 1
        let written = write(ends[1], &byte, 1)
        let failure = errno
        close(ends[1])
        #expect(written == -1 && failure == EPIPE)
    }
}
#endif
