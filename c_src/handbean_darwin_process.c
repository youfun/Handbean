#include "erl_nif.h"

#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define HB_MEMBER_HEADROOM 64U
#define HB_MAX_GROUP_MEMBERS 1048576U
#define HB_CONFIRM_ATTEMPTS 20U

typedef struct {
    pid_t pid;
    uint64_t start_sec;
    uint64_t start_usec;
    uint64_t start_abstime;
} job_identity;

enum check_result {
    CHECK_OK = 0,
    CHECK_NOT_FOUND,
    CHECK_IDENTITY_MISMATCH,
    CHECK_CANNOT_VERIFY,
    CHECK_NO_MEMORY,
    CHECK_STILL_ALIVE,
    CHECK_SIGNAL_FAILED
};

static int process_missing(pid_t pid) {
    int saved;
    errno = 0;
    if (kill(pid, 0) == -1) {
        saved = errno;
        return saved == ESRCH;
    }
    return 0;
}

static enum check_result read_bsd_info(pid_t pid, struct proc_bsdinfo *info) {
    int bytes;
    int saved;
    memset(info, 0, sizeof(*info));
    errno = 0;
    bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, (int)sizeof(*info));
    saved = errno;
    if (bytes == (int)sizeof(*info)) return CHECK_OK;
    if (bytes == 0 && (saved == ESRCH || process_missing(pid))) return CHECK_NOT_FOUND;
    return CHECK_CANNOT_VERIFY;
}

static enum check_result read_start_abstime(pid_t pid, uint64_t *start_abstime) {
    struct rusage_info_v0 usage;
    struct proc_bsdinfo info;
    int saved;
    memset(&usage, 0, sizeof(usage));
    errno = 0;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage) == 0) {
        if (usage.ri_proc_start_abstime == 0) return CHECK_CANNOT_VERIFY;
        *start_abstime = usage.ri_proc_start_abstime;
        return CHECK_OK;
    }
    saved = errno;
    if (saved == ESRCH || process_missing(pid)) return CHECK_NOT_FOUND;
    if (read_bsd_info(pid, &info) == CHECK_OK && info.pbi_status == SZOMB)
        return CHECK_NOT_FOUND;
    return CHECK_CANNOT_VERIFY;
}

static int same_wall_start(const struct proc_bsdinfo *info, const job_identity *identity) {
    return info->pbi_start_tvsec == identity->start_sec &&
           info->pbi_start_tvusec == identity->start_usec;
}

static enum check_result verify_live_leader(const struct proc_bsdinfo *info,
                                             const job_identity *identity) {
    uint64_t start_abstime;
    enum check_result result;
    if (info->pbi_pid != (uint32_t)identity->pid ||
        info->pbi_pgid != (uint32_t)identity->pid ||
        !same_wall_start(info, identity)) {
        return CHECK_IDENTITY_MISMATCH;
    }
    if (info->pbi_status == SZOMB) return CHECK_OK;
    result = read_start_abstime(identity->pid, &start_abstime);
    if (result != CHECK_OK) return result;
    return start_abstime == identity->start_abstime ? CHECK_OK : CHECK_IDENTITY_MISMATCH;
}

static enum check_result list_group_members(pid_t pgid, pid_t **members, size_t *count) {
    size_t capacity;
    int estimate;
    unsigned attempt;

    errno = 0;
    estimate = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, NULL, 0);
    if (estimate < 0) return CHECK_CANNOT_VERIFY;

    capacity = estimate > 0 ? (size_t)estimate / sizeof(pid_t) + HB_MEMBER_HEADROOM
                            : HB_MEMBER_HEADROOM;
    if (capacity < HB_MEMBER_HEADROOM) capacity = HB_MEMBER_HEADROOM;

    for (attempt = 0; attempt < 8; attempt++) {
        pid_t *buffer;
        size_t bytes_capacity;
        int bytes;

        if (capacity > HB_MAX_GROUP_MEMBERS || capacity > (size_t)INT_MAX / sizeof(pid_t))
            return CHECK_CANNOT_VERIFY;
        bytes_capacity = capacity * sizeof(pid_t);
        buffer = enif_alloc(bytes_capacity);
        if (buffer == NULL) return CHECK_NO_MEMORY;
        memset(buffer, 0, bytes_capacity);

        errno = 0;
        bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, buffer, (int)bytes_capacity);
        if (bytes < 0) {
            enif_free(buffer);
            return CHECK_CANNOT_VERIFY;
        }
        if ((size_t)bytes < bytes_capacity) {
            *members = buffer;
            *count = (size_t)bytes / sizeof(pid_t);
            return CHECK_OK;
        }

        enif_free(buffer);
        capacity *= 2;
    }

    return CHECK_CANNOT_VERIFY;
}

static enum check_result validate_group(const job_identity *identity, size_t *live_count) {
    struct proc_bsdinfo leader;
    enum check_result result;
    pid_t *members = NULL;
    size_t count = 0;
    size_t index;

    *live_count = 0;
    result = read_bsd_info(identity->pid, &leader);
    if (result == CHECK_OK) {
        result = verify_live_leader(&leader, identity);
        if (result != CHECK_OK) return result;
    } else if (result != CHECK_NOT_FOUND) {
        return result;
    }

    result = list_group_members(identity->pid, &members, &count);
    if (result != CHECK_OK) return result;

    for (index = 0; index < count; index++) {
        struct proc_bsdinfo info;
        uint64_t start_abstime;
        pid_t member = members[index];

        if (member <= 1) continue;
        result = read_bsd_info(member, &info);
        if (result == CHECK_NOT_FOUND) {
            result = CHECK_OK;
            continue;
        }
        if (result != CHECK_OK) break;
        if (info.pbi_pgid != (uint32_t)identity->pid) {
            result = CHECK_CANNOT_VERIFY;
            break;
        }
        if (info.pbi_status == SZOMB) continue;

        result = read_start_abstime(member, &start_abstime);
        if (result == CHECK_NOT_FOUND) {
            result = CHECK_OK;
            continue;
        }
        if (result != CHECK_OK) break;

        if (member == identity->pid) {
            if (!same_wall_start(&info, identity) ||
                start_abstime != identity->start_abstime) {
                result = CHECK_IDENTITY_MISMATCH;
                break;
            }
        } else if (start_abstime < identity->start_abstime) {
            result = CHECK_IDENTITY_MISMATCH;
            break;
        }

        (*live_count)++;
    }

    enif_free(members);
    return result;
}

static enum check_result signal_group(pid_t pgid, int signal_number) {
    int saved;
    errno = 0;
    if (kill(-pgid, signal_number) == 0) return CHECK_OK;
    saved = errno;
    if (saved == ESRCH) return CHECK_NOT_FOUND;
    return CHECK_SIGNAL_FAILED;
}

static void wait_one_millisecond(void) {
    struct timespec remaining = {0, 1000000L};
    while (nanosleep(&remaining, &remaining) == -1 && errno == EINTR) {
    }
}

static ERL_NIF_TERM error_term(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}

static ERL_NIF_TERM check_term(ErlNifEnv *env, enum check_result result) {
    switch (result) {
    case CHECK_IDENTITY_MISMATCH: return error_term(env, "identity_mismatch");
    case CHECK_NO_MEMORY: return error_term(env, "enomem");
    case CHECK_STILL_ALIVE: return error_term(env, "still_alive");
    case CHECK_SIGNAL_FAILED: return error_term(env, "signal_failed");
    case CHECK_NOT_FOUND: return error_term(env, "enoent");
    default: return error_term(env, "cannot_verify");
    }
}

static ERL_NIF_TERM nif_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static ERL_NIF_TERM nif_verify_group(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int raw_pid;
    pid_t pid;
    pid_t group;
    pid_t session;
    struct proc_bsdinfo info;
    uint64_t start_abstime;
    enum check_result result;
    (void)argc;

    if (!enif_get_int(env, argv[0], &raw_pid) || raw_pid <= 1) return enif_make_badarg(env);
    pid = (pid_t)raw_pid;
    result = read_bsd_info(pid, &info);
    if (result != CHECK_OK) return check_term(env, result);
    if (info.pbi_status == SZOMB) return error_term(env, "identity_mismatch");

    errno = 0;
    group = getpgid(pid);
    if (group == -1) return error_term(env, "cannot_verify");
    errno = 0;
    session = getsid(pid);
    if (session == -1) return error_term(env, "cannot_verify");
    if (info.pbi_pid != (uint32_t)pid || info.pbi_pgid != (uint32_t)pid ||
        group != pid || session != pid) {
        return error_term(env, "identity_mismatch");
    }

    result = read_start_abstime(pid, &start_abstime);
    if (result != CHECK_OK) return check_term(env, result);

    return enif_make_tuple4(env, enif_make_atom(env, "ok"),
                            enif_make_uint64(env, info.pbi_start_tvsec),
                            enif_make_uint64(env, info.pbi_start_tvusec),
                            enif_make_uint64(env, start_abstime));
}

static ERL_NIF_TERM nif_cleanup_group(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int raw_pid;
    ErlNifUInt64 start_sec;
    ErlNifUInt64 start_usec;
    ErlNifUInt64 start_abstime;
    job_identity identity;
    enum check_result result;
    size_t live_count;
    unsigned attempt;
    (void)argc;

    if (!enif_get_int(env, argv[0], &raw_pid) || raw_pid <= 1 ||
        !enif_get_uint64(env, argv[1], &start_sec) ||
        !enif_get_uint64(env, argv[2], &start_usec) ||
        !enif_get_uint64(env, argv[3], &start_abstime) || start_abstime == 0) {
        return enif_make_badarg(env);
    }

    identity.pid = (pid_t)raw_pid;
    identity.start_sec = start_sec;
    identity.start_usec = start_usec;
    identity.start_abstime = start_abstime;

    result = validate_group(&identity, &live_count);
    if (result != CHECK_OK) return check_term(env, result);
    if (live_count == 0) return enif_make_atom(env, "ok");

    result = signal_group(identity.pid, SIGSTOP);
    if (result == CHECK_NOT_FOUND) {
        result = validate_group(&identity, &live_count);
        if (result == CHECK_OK && live_count == 0) return enif_make_atom(env, "ok");
        return check_term(env, result == CHECK_OK ? CHECK_STILL_ALIVE : result);
    }
    if (result != CHECK_OK) return check_term(env, result);

    result = validate_group(&identity, &live_count);
    if (result != CHECK_OK) {
        (void)signal_group(identity.pid, SIGCONT);
        return check_term(env, result);
    }
    if (live_count == 0) return enif_make_atom(env, "ok");

    result = signal_group(identity.pid, SIGKILL);
    if (result != CHECK_OK && result != CHECK_NOT_FOUND) return check_term(env, result);

    for (attempt = 0; attempt < HB_CONFIRM_ATTEMPTS; attempt++) {
        result = validate_group(&identity, &live_count);
        if (result != CHECK_OK) return check_term(env, result);
        if (live_count == 0) return enif_make_atom(env, "ok");
        if (attempt + 1 < HB_CONFIRM_ATTEMPTS) wait_one_millisecond();
    }
    return check_term(env, CHECK_STILL_ALIVE);
}

static ErlNifFunc funcs[] = {
    {"available", 0, nif_available, 0},
    {"verify_group", 1, nif_verify_group, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cleanup_group", 4, nif_cleanup_group, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(handbean_darwin_process, funcs, NULL, NULL, NULL, NULL)
