/* In-process iSH guest. Compiled only with -DHANDREAM_IOS_GUEST.
 *
 * Host fork is not used. become_new_init_child is an iSH syscall inside this
 * process. The three static archives must already be on the link line.
 */
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "fs/devices.h"
#include "fs/dev.h"
#include "fs/real.h"
#include "fs/path.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern const struct fs_ops fakefs;
extern const struct fs_ops procfs;
extern const struct fd_ops realfs_fdops;
extern void (*exit_hook)(struct task *task, int code);

static pthread_mutex_t guest_mu = PTHREAD_MUTEX_INITIALIZER;
static int guest_booted = 0;

struct guest_wait {
  int pid;
  int exited;
  int code;
  pthread_mutex_t mu;
  pthread_cond_t cv;
};

static struct guest_wait *active_wait = NULL;

static void guest_on_exit(struct task *task, int code) {
  struct guest_wait *wait = active_wait;
  if (wait == NULL || task == NULL || task->pid != wait->pid)
    return;
  pthread_mutex_lock(&wait->mu);
  wait->exited = 1;
  wait->code = code;
  pthread_cond_signal(&wait->cv);
  pthread_mutex_unlock(&wait->mu);
}

static int ensure_node(const char *path, mode_t mode, dev_t_ dev) {
  return generic_mknodat(AT_PWD, path, mode, dev);
}

int handbean_ios_guest_linked(void) { return 1; }

int handbean_ios_guest_boot(const char *data_root) {
  int err;
  if (data_root == NULL || data_root[0] == '\0')
    return -EINVAL;

  pthread_mutex_lock(&guest_mu);
  if (guest_booted) {
    pthread_mutex_unlock(&guest_mu);
    return 0;
  }

  err = mount_root(&fakefs, data_root);
  if (err < 0)
    goto done;
  err = become_first_process();
  if (err < 0)
    goto done;
  current->thread = pthread_self();

  ensure_node("/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
  ensure_node("/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
  ensure_node("/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
  ensure_node("/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
  err = do_mount(&procfs, "proc", "/proc", "", 0);
  if (err < 0)
    goto done;

  exit_hook = guest_on_exit;
  guest_booted = 1;
  err = 0;

done:
  pthread_mutex_unlock(&guest_mu);
  return err;
}

static int read_all(int fd, char *buf, size_t cap, size_t *used) {
  while (*used + 1 < cap) {
    ssize_t n = read(fd, buf + *used, cap - *used - 1);
    if (n == 0)
      break;
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    *used += (size_t)n;
  }
  buf[*used] = '\0';
  return 0;
}

int handbean_ios_guest_exec(const char *command, int timeout_ms, int *exit_code, char *output,
                            size_t output_cap) {
  int pipes[2] = {-1, -1};
  int err;
  struct task *saved;
  struct task *task;
  struct guest_wait wait;
  struct timespec deadline;
  char argv[4096];
  /* Double-NUL terminated env block. The second terminator is the extra 0. */
  char envp[] = "HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0\0";
  size_t used = 0;

  if (!guest_booted)
    return -ENODEV;
  if (command == NULL || command[0] == '\0' || exit_code == NULL || output == NULL || output_cap < 2)
    return -EINVAL;
  if (strlen(command) + 16 >= sizeof(argv))
    return -E2BIG;

  if (pipe(pipes) != 0)
    return -errno;

  memset(&wait, 0, sizeof(wait));
  pthread_mutex_init(&wait.mu, NULL);
  pthread_cond_init(&wait.cv, NULL);

  saved = current;
  err = become_new_init_child();
  if (err < 0) {
    current = saved;
    goto fail;
  }
  task = current;

  {
    struct fd *in = adhoc_fd_create(&realfs_fdops);
    struct fd *out = adhoc_fd_create(&realfs_fdops);
    struct fd *err_fd = adhoc_fd_create(&realfs_fdops);
    if (in == NULL || out == NULL || err_fd == NULL) {
      err = -ENOMEM;
      current = saved;
      goto fail;
    }
    in->real_fd = open("/dev/null", O_RDONLY);
    out->real_fd = dup(pipes[1]);
    err_fd->real_fd = dup(pipes[1]);
    task->files->files[0] = in;
    task->files->files[1] = out;
    task->files->files[2] = err_fd;
  }
  close(pipes[1]);
  pipes[1] = -1;

  memcpy(argv, "/bin/sh", 8);
  memcpy(argv + 8, "-c", 3);
  memcpy(argv + 11, command, strlen(command) + 1);
  argv[11 + strlen(command) + 1] = '\0';

  err = do_execve("/bin/sh", 3, argv, envp);
  if (err < 0) {
    current = saved;
    goto fail;
  }

  wait.pid = task->pid;
  active_wait = &wait;
  err = task_start(task);
  current = saved;
  if (err < 0)
    goto fail;

  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }

  pthread_mutex_lock(&wait.mu);
  while (!wait.exited) {
    err = pthread_cond_timedwait(&wait.cv, &wait.mu, &deadline);
    if (err == ETIMEDOUT) {
      pthread_mutex_unlock(&wait.mu);
      err = -ETIMEDOUT;
      goto fail;
    }
  }
  *exit_code = wait.code >> 8;
  pthread_mutex_unlock(&wait.mu);
  active_wait = NULL;

  if (read_all(pipes[0], output, output_cap, &used) != 0) {
    err = -EIO;
    goto fail;
  }
  close(pipes[0]);
  pthread_cond_destroy(&wait.cv);
  pthread_mutex_destroy(&wait.mu);
  return 0;

fail:
  active_wait = NULL;
  if (pipes[0] >= 0)
    close(pipes[0]);
  if (pipes[1] >= 0)
    close(pipes[1]);
  pthread_cond_destroy(&wait.cv);
  pthread_mutex_destroy(&wait.mu);
  return err;
}
