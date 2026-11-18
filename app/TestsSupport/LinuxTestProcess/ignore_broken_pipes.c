// Linux test processes ignore SIGPIPE from their first instruction, as the
// product's Linux hosts do (PortablePOSIX.ignoreBrokenPipes). A test that writes
// to a pipe or socket whose reader has gone then gets EPIPE instead of the whole
// runner being killed. swift test does not pass an ignored SIGPIPE on to its
// runner, so a shell `trap '' PIPE` alone is not enough.
#include "LinuxTestProcess.h"
#ifdef __linux__
#include <signal.h>
__attribute__((constructor)) static void woven_ignore_broken_pipes(void) { signal(SIGPIPE, SIG_IGN); }
#endif
int woven_linux_test_process_linked = 1;
