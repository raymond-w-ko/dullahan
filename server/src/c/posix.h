// C declarations for PTY, process, and terminal-size code.
// build.zig translates this header into the `posix_c` module.
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#if defined(__APPLE__)
#include <util.h> // openpty() on macOS
#else
#include <pty.h> // openpty() on Linux
#endif
