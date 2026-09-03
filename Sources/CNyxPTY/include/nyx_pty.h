#ifndef NYX_PTY_H
#define NYX_PTY_H
#include <sys/types.h>

typedef struct {
    int fd;      /* master fd, or -1 on failure */
    pid_t pid;   /* child pid, or -1 */
    int err;     /* errno when fd == -1 */
} nyx_pty_result;

/* forkpty + execve. argv/envp are NULL-terminated. cwd may be NULL. */
nyx_pty_result nyx_pty_spawn(const char *path, char *const argv[], char *const envp[],
                             const char *cwd, unsigned short cols, unsigned short rows);

/* Returns 0 on success, errno otherwise. */
int nyx_pty_resize(int fd, unsigned short cols, unsigned short rows);

#endif
