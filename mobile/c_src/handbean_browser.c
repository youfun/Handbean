#include <erl_nif.h>
#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>

extern JavaVM* g_jvm;

static jclass g_engine_cls = NULL;
static jclass g_bridge_cls = NULL;
static jmethodID g_create = NULL;
static jmethodID g_load = NULL;
static jmethodID g_eval = NULL;
static jmethodID g_back = NULL;
static jmethodID g_show = NULL;
static jmethodID g_hide = NULL;
static jmethodID g_destroy = NULL;
static jmethodID g_open_external = NULL;
static jmethodID g_platform = NULL;
static pthread_mutex_t g_jni_cache_lock = PTHREAD_MUTEX_INITIALIZER;

static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_async;
static ERL_NIF_TERM am_engine_result;

#define MAX_PENDING 64

typedef struct {
    int used;
    char request_id[64];
    ErlNifPid pid;
} pending_t;

static pending_t g_pending[MAX_PENDING];
static ErlNifMutex* g_pending_lock = NULL;
static atomic_bool nif_ready = 0;

enum pending_put_result { PENDING_OK, PENDING_DUPLICATE, PENDING_FULL, PENDING_INVALID };

static enum pending_put_result pending_put(const char* request_id, ErlNifPid pid) {
    enum pending_put_result result = PENDING_FULL;
    if (!g_pending_lock || !request_id) return PENDING_FULL;
    if (strlen(request_id) >= sizeof(g_pending[0].request_id)) return PENDING_INVALID;
    enif_mutex_lock(g_pending_lock);
    for (int i = 0; i < MAX_PENDING; i++) {
        if (g_pending[i].used && strcmp(g_pending[i].request_id, request_id) == 0) {
            result = PENDING_DUPLICATE;
            goto done;
        }
    }
    for (int i = 0; i < MAX_PENDING; i++) {
        if (!g_pending[i].used) {
            g_pending[i].used = 1;
            strncpy(g_pending[i].request_id, request_id, sizeof(g_pending[i].request_id) - 1);
            g_pending[i].request_id[sizeof(g_pending[i].request_id) - 1] = 0;
            g_pending[i].pid = pid;
            result = PENDING_OK;
            break;
        }
    }
done:
    enif_mutex_unlock(g_pending_lock);
    return result;
}

static int pending_take(const char* request_id, ErlNifPid* pid) {
    int found = 0;
    if (!g_pending_lock || !request_id) return 0;
    enif_mutex_lock(g_pending_lock);
    for (int i = 0; i < MAX_PENDING; i++) {
        if (g_pending[i].used && strcmp(g_pending[i].request_id, request_id) == 0) {
            *pid = g_pending[i].pid;
            g_pending[i].used = 0;
            found = 1;
            break;
        }
    }
    enif_mutex_unlock(g_pending_lock);
    return found;
}

static JNIEnv* jni_env(void) {
    JNIEnv* env = NULL;
    if (!g_jvm) return NULL;
    if ((*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != JNI_OK) return NULL;
    }
    return env;
}

static size_t utf8_size(uint32_t codepoint) {
    if (codepoint <= 0x7f) return 1;
    if (codepoint <= 0x7ff) return 2;
    if (codepoint <= 0xffff) return 3;
    return 4;
}

static unsigned char* utf8_write(unsigned char* out, uint32_t codepoint) {
    if (codepoint <= 0x7f) {
        *out++ = (unsigned char)codepoint;
    } else if (codepoint <= 0x7ff) {
        *out++ = (unsigned char)(0xc0 | (codepoint >> 6));
        *out++ = (unsigned char)(0x80 | (codepoint & 0x3f));
    } else if (codepoint <= 0xffff) {
        *out++ = (unsigned char)(0xe0 | (codepoint >> 12));
        *out++ = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
        *out++ = (unsigned char)(0x80 | (codepoint & 0x3f));
    } else {
        *out++ = (unsigned char)(0xf0 | (codepoint >> 18));
        *out++ = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3f));
        *out++ = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
        *out++ = (unsigned char)(0x80 | (codepoint & 0x3f));
    }
    return out;
}

static uint32_t next_codepoint(const jchar* chars, jsize length, jsize* index) {
    uint32_t first = chars[(*index)++];
    if (first >= 0xd800 && first <= 0xdbff && *index < length) {
        uint32_t second = chars[*index];
        if (second >= 0xdc00 && second <= 0xdfff) {
            (*index)++;
            return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
        }
    }
    if (first >= 0xd800 && first <= 0xdfff) return 0xfffd;
    return first;
}

static int make_jstring_binary(
    ErlNifEnv* msg_env,
    JNIEnv* env,
    jstring value,
    ERL_NIF_TERM* term
) {
    jsize length = (*env)->GetStringLength(env, value);
    const jchar* chars = (*env)->GetStringChars(env, value, NULL);
    if (!chars) return 0;

    size_t byte_size = 0;
    for (jsize i = 0; i < length;) {
        byte_size += utf8_size(next_codepoint(chars, length, &i));
    }

    unsigned char* data = enif_make_new_binary(msg_env, byte_size, term);
    if (!data && byte_size != 0) {
        (*env)->ReleaseStringChars(env, value, chars);
        return 0;
    }

    unsigned char* cursor = data;
    for (jsize i = 0; i < length;) {
        cursor = utf8_write(cursor, next_codepoint(chars, length, &i));
    }

    (*env)->ReleaseStringChars(env, value, chars);
    return 1;
}

static int make_jbyte_array_binary(
    ErlNifEnv* msg_env,
    JNIEnv* env,
    jbyteArray value,
    ERL_NIF_TERM* term
) {
    if (!value) return 0;

    jsize length = (*env)->GetArrayLength(env, value);
    unsigned char* data = enif_make_new_binary(msg_env, (size_t)length, term);
    if (!data && length != 0) return 0;
    if (length > 0) {
        (*env)->GetByteArrayRegion(env, value, 0, length, (jbyte*)data);
    }
    return 1;
}

JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_BrowserEngine_nativeInitClass(JNIEnv* env, jclass cls) {
    pthread_mutex_lock(&g_jni_cache_lock);
    if (g_engine_cls) {
        pthread_mutex_unlock(&g_jni_cache_lock);
        return;
    }

    jclass global = (*env)->NewGlobalRef(env, cls);
    if (!global) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        pthread_mutex_unlock(&g_jni_cache_lock);
        return;
    }

    jmethodID create = (*env)->GetStaticMethodID(env, global, "create",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IJ)V");
    jmethodID load = create ? (*env)->GetStaticMethodID(env, global, "load",
        "(Ljava/lang/String;Ljava/lang/String;ILjava/lang/String;J)V") : NULL;
    jmethodID eval = load ? (*env)->GetStaticMethodID(env, global, "eval",
        "(Ljava/lang/String;Ljava/lang/String;ILjava/lang/String;J)V") : NULL;
    jmethodID back = eval ? (*env)->GetStaticMethodID(env, global, "back",
        "(Ljava/lang/String;Ljava/lang/String;IJ)V") : NULL;
    jmethodID show = back ? (*env)->GetStaticMethodID(env, global, "show",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V") : NULL;
    jmethodID hide = show ? (*env)->GetStaticMethodID(env, global, "hide",
        "(Ljava/lang/String;Ljava/lang/String;)V") : NULL;
    jmethodID destroy = hide ? (*env)->GetStaticMethodID(env, global, "destroy",
        "(Ljava/lang/String;I)V") : NULL;
    jmethodID open_external = destroy ? (*env)->GetStaticMethodID(env, global, "openExternal",
        "(Ljava/lang/String;)V") : NULL;
    if (!create || !load || !eval || !back || !show || !hide || !destroy || !open_external) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        pthread_mutex_unlock(&g_jni_cache_lock);
        return;
    }

    g_create = create;
    g_load = load;
    g_eval = eval;
    g_back = back;
    g_show = show;
    g_hide = hide;
    g_destroy = destroy;
    g_open_external = open_external;
    g_engine_cls = global;
    pthread_mutex_unlock(&g_jni_cache_lock);
}

JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_MobBridge_nativeInitPlatformClass(JNIEnv* env, jclass cls) {
    pthread_mutex_lock(&g_jni_cache_lock);
    if (!g_bridge_cls) {
        jclass global = (*env)->NewGlobalRef(env, cls);
        jmethodID platform = global ? (*env)->GetStaticMethodID(env, global, "platformCommand",
            "(Ljava/lang/String;Ljava/lang/String;I)V") : NULL;
        if (global && platform && !(*env)->ExceptionCheck(env)) {
            g_platform = platform;
            g_bridge_cls = global;
        } else {
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
            if (global) (*env)->DeleteGlobalRef(env, global);
        }
    }
    pthread_mutex_unlock(&g_jni_cache_lock);
}

/* JNI's NewStringUTF accepts modified UTF-8, not Erlang's standard UTF-8. */
static jstring new_utf8_string(JNIEnv* env, const char* input) {
    if (!input) return NULL;
    size_t length = strlen(input);
    jchar* utf16 = malloc((length + 1) * sizeof(jchar));
    if (!utf16) return NULL;
    size_t i = 0, out = 0;
    while (i < length) {
        unsigned char c = (unsigned char)input[i++];
        uint32_t cp;
        int extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c & 0xe0) == 0xc0) { cp = c & 0x1f; extra = 1; }
        else if ((c & 0xf0) == 0xe0) { cp = c & 0x0f; extra = 2; }
        else if ((c & 0xf8) == 0xf0) { cp = c & 0x07; extra = 3; }
        else { free(utf16); return NULL; }
        if (i + (size_t)extra > length) { free(utf16); return NULL; }
        for (int n = 0; n < extra; n++) {
            unsigned char trail = (unsigned char)input[i++];
            if ((trail & 0xc0) != 0x80) { free(utf16); return NULL; }
            cp = (cp << 6) | (trail & 0x3f);
        }
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) ||
            (extra == 3 && cp < 0x10000) || cp > 0x10ffff ||
            (cp >= 0xd800 && cp <= 0xdfff)) { free(utf16); return NULL; }
        if (cp <= 0xffff) utf16[out++] = (jchar)cp;
        else {
            cp -= 0x10000;
            utf16[out++] = (jchar)(0xd800 + (cp >> 10));
            utf16[out++] = (jchar)(0xdc00 + (cp & 0x3ff));
        }
    }
    jstring result = (*env)->NewString(env, utf16, (jsize)out);
    free(utf16);
    return result;
}

static char* bin_copy(ErlNifEnv* env, ERL_NIF_TERM term) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) && !enif_inspect_iolist_as_binary(env, term, &bin)) {
        char atom[64];
        unsigned len;
        if (enif_get_atom_length(env, term, &len, ERL_NIF_LATIN1) && len < sizeof(atom)) {
            enif_get_atom(env, term, atom, sizeof(atom), ERL_NIF_LATIN1);
            char* out = enif_alloc(len + 1);
            memcpy(out, atom, len + 1);
            return out;
        }
        return NULL;
    }
    char* out = enif_alloc(bin.size + 1);
    if (!out) return NULL;
    memcpy(out, bin.data, bin.size);
    out[bin.size] = 0;
    return out;
}

static int map_get_bin(ErlNifEnv* env, ERL_NIF_TERM map, const char* key, char** out) {
    ERL_NIF_TERM k = enif_make_atom(env, key);
    ERL_NIF_TERM v;
    if (!enif_get_map_value(env, map, k, &v)) return 0;
    *out = bin_copy(env, v);
    return *out != NULL;
}

static int map_get_int(ErlNifEnv* env, ERL_NIF_TERM map, const char* key, int* out) {
    ERL_NIF_TERM k = enif_make_atom(env, key);
    ERL_NIF_TERM v;
    if (!enif_get_map_value(env, map, k, &v)) return 0;
    return enif_get_int(env, v, out);
}

static ERL_NIF_TERM command(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc < 1 || !enif_is_map(env, argv[0])) return enif_make_badarg(env);
    JNIEnv* jenv = jni_env();
    if (!jenv || !g_engine_cls) {
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "engine_unavailable"));
    }

    char* op = NULL;
    char* session_id = NULL;
    char* request_id = NULL;
    char* owner = NULL;
    char* conversation_id = NULL;
    char* url = NULL;
    char* js = NULL;
    char* control = NULL;
    int generation = 1;
    map_get_bin(env, argv[0], "op", &op);
    map_get_bin(env, argv[0], "session_id", &session_id);
    map_get_bin(env, argv[0], "id", &session_id);
    map_get_bin(env, argv[0], "request_id", &request_id);
    map_get_bin(env, argv[0], "owner", &owner);
    map_get_bin(env, argv[0], "conversation_id", &conversation_id);
    map_get_bin(env, argv[0], "url", &url);
    map_get_bin(env, argv[0], "js", &js);
    map_get_bin(env, argv[0], "control", &control);
    map_get_int(env, argv[0], "generation", &generation);
    if (!op) {
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "missing_op"));
    }

    ErlNifPid self;
    ERL_NIF_TERM caller;
    if (!(enif_get_map_value(env, argv[0], enif_make_atom(env, "caller"), &caller) &&
          enif_get_local_pid(env, caller, &self))) {
        enif_self(env, &self);
    }
    int is_platform = strncmp(op, "platform_", 9) == 0;
    int expects_result = is_platform || strcmp(op, "load") == 0 ||
        strcmp(op, "eval") == 0 || strcmp(op, "back") == 0;
    if (expects_result && !request_id) {
        if (op) enif_free(op);
        if (session_id) enif_free(session_id);
        return enif_make_tuple2(env, am_error, enif_make_atom(env, "missing_request_id"));
    }
    if (expects_result) {
        enum pending_put_result put = pending_put(request_id, self);
        if (put != PENDING_OK) {
            if (op) enif_free(op);
            if (session_id) enif_free(session_id);
            if (request_id) enif_free(request_id);
            return enif_make_tuple2(env, am_error,
                enif_make_atom(env, put == PENDING_DUPLICATE ? "duplicate_request_id" :
                    (put == PENDING_INVALID ? "invalid_request_id" : "busy")));
        }
    }

    jstring j_session = new_utf8_string(jenv, session_id);
    jstring j_request = new_utf8_string(jenv, request_id);
    jstring j_owner = new_utf8_string(jenv, owner ? owner : "browser");
    jstring j_conv = new_utf8_string(jenv, conversation_id ? conversation_id : "");
    jstring j_url = new_utf8_string(jenv, url);
    jstring j_js = new_utf8_string(jenv, js);
    jstring j_control = new_utf8_string(jenv, control ? control : "agent");
    jlong pid_token = 0;
    int dispatched = 0;

    if (is_platform) {
        if (g_bridge_cls && g_platform && j_request) {
            char* payload = NULL;
            map_get_bin(env, argv[0], "payload", &payload);
            jstring j_payload = new_utf8_string(jenv, payload ? payload : "{}");
            if (j_payload) {
                (*jenv)->CallStaticVoidMethod(jenv, g_bridge_cls, g_platform, j_request, j_payload, generation);
                dispatched = !(*jenv)->ExceptionCheck(jenv);
            }
            if (j_payload) (*jenv)->DeleteLocalRef(jenv, j_payload);
            if (payload) enif_free(payload);
        }
    } else if (strcmp(op, "create") == 0 && j_session) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_create, j_session, j_owner, j_conv, generation, pid_token);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "load") == 0) && j_session && j_request && j_url) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_load, j_session, j_request, generation, j_url, pid_token);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "eval") == 0) && j_session && j_request && j_js) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_eval, j_session, j_request, generation, j_js, pid_token);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "back") == 0) && j_session && j_request) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_back, j_session, j_request, generation, pid_token);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "show") == 0 || strcmp(op, "open_external") == 0) && j_session) {
        if (strcmp(op, "open_external") == 0 && j_url) {
            (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_open_external, j_url);
        } else {
            (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_show, j_owner, j_session, j_conv, j_url, j_control);
        }
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "hide") == 0) && j_session) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_hide, j_owner, j_session);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    } else if ((strcmp(op, "destroy") == 0) && j_session) {
        (*jenv)->CallStaticVoidMethod(jenv, g_engine_cls, g_destroy, j_session, generation);
        dispatched = !(*jenv)->ExceptionCheck(jenv);
    }

    int jni_exception = (*jenv)->ExceptionCheck(jenv);
    if (jni_exception) (*jenv)->ExceptionClear(jenv);
    if (!dispatched && expects_result) {
        ErlNifPid ignored;
        pending_take(request_id, &ignored);
    }

    if (j_session) (*jenv)->DeleteLocalRef(jenv, j_session);
    if (j_request) (*jenv)->DeleteLocalRef(jenv, j_request);
    (*jenv)->DeleteLocalRef(jenv, j_owner);
    (*jenv)->DeleteLocalRef(jenv, j_conv);
    if (j_url) (*jenv)->DeleteLocalRef(jenv, j_url);
    if (j_js) (*jenv)->DeleteLocalRef(jenv, j_js);
    (*jenv)->DeleteLocalRef(jenv, j_control);

    if (op) enif_free(op);
    if (session_id) enif_free(session_id);
    if (request_id) enif_free(request_id);
    if (owner) enif_free(owner);
    if (conversation_id) enif_free(conversation_id);
    if (url) enif_free(url);
    if (js) enif_free(js);
    if (control) enif_free(control);

    if (!dispatched) {
        return enif_make_tuple2(env, am_error,
            enif_make_atom(env, jni_exception ? "jni_exception" :
                (is_platform && !g_bridge_cls ? "platform_unavailable" : "invalid_command")));
    }
    return enif_make_tuple2(env, am_error, am_async);
}

static int onload(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    (void)priv; (void)info;
    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_async = enif_make_atom(env, "async");
    am_engine_result = enif_make_atom(env, "engine_result");
    g_pending_lock = enif_mutex_create("handbean_browser_pending");
    if (!g_pending_lock) return 1;
    atomic_store(&nif_ready, 1);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"command", 1, command, 0}
};

ERL_NIF_INIT(handbean_browser, nif_funcs, onload, NULL, NULL, NULL)

/* JNI callbacks from BrowserEngine */
JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_BrowserEngine_nativeDeliver(
    JNIEnv* env, jclass cls,
    jlong pid_unused,
    jbyteArray sessionId,
    jbyteArray requestId,
    jint generation,
    jbyteArray result,
    jbyteArray error,
    jbyteArray url
) {
    (void)cls; (void)pid_unused;
    if (!atomic_load(&nif_ready)) return;
    if (!requestId) return;

    jsize req_len = (*env)->GetArrayLength(env, requestId);
    char* request = enif_alloc((size_t)req_len + 1);
    if (!request) return;
    if (req_len > 0) {
        (*env)->GetByteArrayRegion(env, requestId, 0, req_len, (jbyte*)request);
    }
    request[req_len] = 0;

    ErlNifPid dest;
    if (!pending_take(request, &dest)) {
        enif_free(request);
        return;
    }

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM map = enif_make_new_map(msg_env);

    ERL_NIF_TERM bin;
    if (sessionId && make_jbyte_array_binary(msg_env, env, sessionId, &bin)) {
        enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "session_id"), bin, &map);
    }
    ERL_NIF_TERM req_bin;
    if (make_jbyte_array_binary(msg_env, env, requestId, &req_bin)) {
        enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "request_id"), req_bin, &map);
    }
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "generation"),
                      enif_make_int(msg_env, generation), &map);
    if (result) {
        ERL_NIF_TERM result_bin;
        if (make_jbyte_array_binary(msg_env, env, result, &result_bin)) {
            enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "result"), result_bin, &map);
        }
    }
    if (error) {
        ERL_NIF_TERM error_bin;
        if (make_jbyte_array_binary(msg_env, env, error, &error_bin)) {
            enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "error"), error_bin, &map);
        }
    }
    if (url) {
        ERL_NIF_TERM url_bin;
        if (make_jbyte_array_binary(msg_env, env, url, &url_bin)) {
            enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "url"), url_bin, &map);
        }
    }

    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, "engine_result"), map);
    enif_send(NULL, &dest, msg_env, msg);
    enif_free_env(msg_env);
    enif_free(request);
}

JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_BrowserEngine_nativeHandback(JNIEnv* env, jclass cls, jstring sessionId, jlong pid_unused) {
    (void)env; (void)cls; (void)sessionId; (void)pid_unused;
    /* Handback is delivered through the OTP session API from Elixir, not JNI. */
}

JNIEXPORT void JNICALL
Java_com_example_handbean_1probe_BrowserEngine_nativeShareIntakeReady(
    JNIEnv* env, jclass cls, jstring intakeId, jstring status
) {
    (void)cls;
    if (!atomic_load(&nif_ready)) return;
    ErlNifEnv* msg_env = enif_alloc_env();
    if (!msg_env) return;
    ErlNifPid pid;
    if (!enif_whereis_pid(msg_env, enif_make_atom(msg_env, "mob_screen"), &pid)) {
        enif_free_env(msg_env);
        return;
    }
    ERL_NIF_TERM id_bin;
    ERL_NIF_TERM status_bin;
    if (!make_jstring_binary(msg_env, env, intakeId, &id_bin)) {
        enif_free_env(msg_env);
        return;
    }
    if (!make_jstring_binary(msg_env, env, status, &status_bin)) {
        enif_free_env(msg_env);
        return;
    }
    ERL_NIF_TERM msg = enif_make_tuple3(
        msg_env,
        enif_make_atom(msg_env, "share_intake_ready"),
        id_bin,
        status_bin
    );
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}
