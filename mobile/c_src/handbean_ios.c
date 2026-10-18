/* handbean_ios — thin C NIF. UIKit present lives in ios/AppDelegate.m.
 * Guest exec is compiled in only with -DHANDREAM_IOS_GUEST. */
#include <erl_nif.h>
#include <string.h>

#ifdef HANDREAM_IOS_GUEST
#include "handbean_ios_guest.h"
#else
static int handbean_ios_guest_linked(void) { return 0; }
#endif

extern int sigil_present_file(const char *path, const char *mode);

static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;

static int copy_iolist(ErlNifEnv *env, ERL_NIF_TERM term, char *buf, size_t buf_size) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) && !enif_inspect_iolist_as_binary(env, term, &bin))
    return 0;
  if (bin.size + 1 > buf_size)
    return 0;
  memcpy(buf, bin.data, bin.size);
  buf[bin.size] = 0;
  return 1;
}

static ERL_NIF_TERM nif_guest_linked(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0)
    return enif_make_badarg(env);
  return handbean_ios_guest_linked() ? am_ok : enif_make_atom(env, "false");
}

static ERL_NIF_TERM nif_guest_exec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
#ifndef HANDREAM_IOS_GUEST
  (void)argc;
  (void)argv;
  return enif_make_tuple2(env, am_error, enif_make_atom(env, "guest_not_linked"));
#else
  char root[1024];
  char command[2048];
  char output[65536];
  int timeout_ms;
  int exit_code = 0;
  int err;
  if (argc != 3)
    return enif_make_badarg(env);
  if (!enif_get_int(env, argv[0], &timeout_ms) || timeout_ms <= 0)
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "invalid_command"));
  if (!copy_iolist(env, argv[1], root, sizeof(root)) || !copy_iolist(env, argv[2], command, sizeof(command)))
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "invalid_command"));
  err = handbean_ios_guest_boot(root);
  if (err < 0)
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "guest_boot_failed"));
  err = handbean_ios_guest_exec(command, timeout_ms, &exit_code, output, sizeof(output));
  if (err < 0)
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "guest_exec_failed"));
  return enif_make_tuple3(env, am_ok, enif_make_int(env, exit_code), enif_make_string(env, output, ERL_NIF_LATIN1));
#endif
}

static ERL_NIF_TERM nif_present_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  char path[4096];
  char mode[16];
  if (argc != 2)
    return enif_make_badarg(env);
  if (!copy_iolist(env, argv[0], path, sizeof(path)))
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  if (!copy_iolist(env, argv[1], mode, sizeof(mode)))
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  if (sigil_present_file(path, mode) != 0)
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  return am_ok;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  am_ok = enif_make_atom(env, "ok");
  am_error = enif_make_atom(env, "error");
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"present_file", 2, nif_present_file, 0},
    {"guest_linked", 0, nif_guest_linked, 0},
    {"guest_exec", 3, nif_guest_exec, 0},
};

ERL_NIF_INIT(handbean_ios, nif_funcs, load, NULL, NULL, NULL)
