/* handbean_notify — Android run-lifecycle notifications.
 *
 * Compiled with -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=handbean_notify
 * so ERL_NIF_INIT emits handbean_notify_nif_init().
 */
#include <erl_nif.h>
#include <jni.h>
#include <stdint.h>
#include <stdatomic.h>

extern JavaVM *g_jvm;

static atomic_bool nif_ready = 0;
static jclass notify_class = NULL;
static jmethodID app_visible_method = NULL;
static jmethodID update_running_method = NULL;
static jmethodID show_ended_method = NULL;

static JNIEnv *jenv(void) {
  JNIEnv *env = NULL;
  if (!g_jvm)
    return NULL;
  if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) == JNI_OK)
    return env;
  if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) == 0)
    return env;
  return NULL;
}

JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_AgentNotify_nativeInitClass(JNIEnv *env, jclass cls) {
  if (notify_class)
    return;

  jclass global = (*env)->NewGlobalRef(env, cls);
  if (!global) {
    if ((*env)->ExceptionCheck(env))
      (*env)->ExceptionClear(env);
    return;
  }

  /* Payloads cross JNI as raw UTF-8 bytes ([B), never java.lang.String:
   * NewStringUTF expects modified UTF-8 and corrupts non-BMP text (emoji). */
  jmethodID visible = (*env)->GetStaticMethodID(env, global, "appVisible", "()Z");
  jmethodID update = visible ? (*env)->GetStaticMethodID(env, global, "updateRunning", "([B)V") : NULL;
  jmethodID ended = update ? (*env)->GetStaticMethodID(env, global, "showEnded", "([B)V") : NULL;
  if (!visible || !update || !ended) {
    if ((*env)->ExceptionCheck(env))
      (*env)->ExceptionClear(env);
    (*env)->DeleteGlobalRef(env, global);
    return;
  }

  app_visible_method = visible;
  update_running_method = update;
  show_ended_method = ended;
  notify_class = global;
}

static ERL_NIF_TERM atom_ok(ErlNifEnv *env) { return enif_make_atom(env, "ok"); }
static ERL_NIF_TERM atom_true(ErlNifEnv *env) { return enif_make_atom(env, "true"); }
static ERL_NIF_TERM atom_false(ErlNifEnv *env) { return enif_make_atom(env, "false"); }

/* Copy an Erlang binary / iolist into a fresh Java byte[] (standard UTF-8 as-is).
 * Returns NULL (with any pending exception cleared) on failure. */
static jbyteArray new_utf8_bytes(ErlNifEnv *env, ERL_NIF_TERM term, JNIEnv *jni) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) && !enif_inspect_iolist_as_binary(env, term, &bin))
    return NULL;
  if (bin.size > (size_t)INT32_MAX)
    return NULL;

  jbyteArray bytes = (*jni)->NewByteArray(jni, (jsize)bin.size);
  if (!bytes) {
    if ((*jni)->ExceptionCheck(jni))
      (*jni)->ExceptionClear(jni);
    return NULL;
  }
  if (bin.size > 0) {
    (*jni)->SetByteArrayRegion(jni, bytes, 0, (jsize)bin.size, (const jbyte *)bin.data);
    if ((*jni)->ExceptionCheck(jni)) {
      (*jni)->ExceptionClear(jni);
      (*jni)->DeleteLocalRef(jni, bytes);
      return NULL;
    }
  }
  return bytes;
}

static ERL_NIF_TERM app_visible(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  JNIEnv *jni = jenv();
  if (!jni)
    return atom_false(env);

  if (!notify_class || !app_visible_method)
    return atom_false(env);

  jboolean visible = (*jni)->CallStaticBooleanMethod(jni, notify_class, app_visible_method);
  if ((*jni)->ExceptionCheck(jni)) {
    (*jni)->ExceptionClear(jni);
    return atom_false(env);
  }
  return visible ? atom_true(env) : atom_false(env);
}

static ERL_NIF_TERM call_utf8(ErlNifEnv *env, const ERL_NIF_TERM argv[], jmethodID mid) {
  JNIEnv *jni = jenv();
  if (!jni)
    return atom_ok(env);

  if (!notify_class || !mid)
    return atom_ok(env);

  jbyteArray jjson = new_utf8_bytes(env, argv[0], jni);
  if (!jjson)
    return atom_ok(env);

  (*jni)->CallStaticVoidMethod(jni, notify_class, mid, jjson);
  (*jni)->DeleteLocalRef(jni, jjson);
  if ((*jni)->ExceptionCheck(jni))
    (*jni)->ExceptionClear(jni);
  return atom_ok(env);
}

static ERL_NIF_TERM update_running(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  return call_utf8(env, argv, update_running_method);
}

static ERL_NIF_TERM show_ended(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  return call_utf8(env, argv, show_ended_method);
}

static ErlNifFunc nif_funcs[] = {
    {"app_visible", 0, app_visible, 0},
    {"update_running", 1, update_running, 0},
    {"show_ended", 1, show_ended, 0},
};

/* Local notification taps do not require the optional push plugin.
 * `json` is the UTF-8 encoded tap payload (Kotlin: String.toByteArray(UTF_8)). */
JNIEXPORT jboolean JNICALL
Java_com_example_handbean_1probe_AgentNotify_nativeOpenConversation(JNIEnv *jni, jclass cls, jbyteArray json) {
  (void)cls;
  if (!atomic_load(&nif_ready)) return JNI_FALSE;
  if (!json) return JNI_FALSE;
  ErlNifEnv *env = enif_alloc_env();
  if (!env) return JNI_FALSE;
  ErlNifPid pid;
  int sent = 0;
  if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
    jsize size = (*jni)->GetArrayLength(jni, json);
    ERL_NIF_TERM payload;
    unsigned char *data = enif_make_new_binary(env, (size_t)size, &payload);
    if (data || size == 0) {
      if (size > 0)
        (*jni)->GetByteArrayRegion(jni, json, 0, size, (jbyte *)data);
      if ((*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionClear(jni);
      } else {
        sent = enif_send(NULL, &pid, env, enif_make_tuple2(env,
            enif_make_atom(env, "mob_launch_notification"), payload));
      }
    }
  }
  enif_free_env(env);
  return sent ? JNI_TRUE : JNI_FALSE;
}

static int onload(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)env; (void)priv; (void)info;
  atomic_store(&nif_ready, 1);
  return 0;
}

ERL_NIF_INIT(handbean_notify, nif_funcs, onload, NULL, NULL, NULL)
