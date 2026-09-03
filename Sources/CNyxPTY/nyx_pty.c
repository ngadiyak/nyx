#include "nyx_pty.h"
#include <util.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <string.h>

nyx_pty_result nyx_pty_spawn(const char *path, char *const argv[], char *const envp[],
                             const char *cwd, unsigned short cols, unsigned short rows) {
    nyx_pty_result r = { -1, -1, 0 };
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols;
    ws.ws_row = rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) { r.err = errno; return r; }
    if (pid == 0) {
        sigset_t set;
        sigemptyset(&set);
        sigprocmask(SIG_SETMASK, &set, NULL);
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
        if (cwd != NULL && chdir(cwd) != 0) { /* keep inherited cwd */ }
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    r.fd = master;
    r.pid = pid;
    return r;
}

int nyx_pty_resize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(fd, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}
