#include "CMPVShim.h"

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void mpv_handle;
typedef void mpv_render_context;

typedef enum mpv_format {
    MPV_FORMAT_NONE = 0,
    MPV_FORMAT_STRING = 1,
    MPV_FORMAT_OSD_STRING = 2,
    MPV_FORMAT_FLAG = 3,
    MPV_FORMAT_INT64 = 4,
    MPV_FORMAT_DOUBLE = 5,
    MPV_FORMAT_NODE = 6,
    MPV_FORMAT_NODE_ARRAY = 7,
    MPV_FORMAT_NODE_MAP = 8,
    MPV_FORMAT_BYTE_ARRAY = 9
} mpv_format;

typedef struct mpv_node mpv_node;

typedef struct mpv_node_list {
    int num;
    mpv_node *values;
    char **keys;
} mpv_node_list;

struct mpv_node {
    union {
        char *string;
        int flag;
        int64_t int64;
        double double_value;
        mpv_node_list *list;
        void *byte_array;
    } value;
    mpv_format format;
};

typedef struct mpv_event {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;

typedef struct mpv_event_property {
    const char *name;
    mpv_format format;
    void *data;
} mpv_event_property;

typedef struct mpv_event_end_file {
    int reason;
    int error;
    int64_t playlist_entry_id;
    int64_t playlist_insert_id;
    int playlist_insert_num_entries;
} mpv_event_end_file;

typedef struct mpv_render_param {
    int type;
    void *data;
} mpv_render_param;

typedef struct mpv_opengl_init_params {
    void *(*get_proc_address)(void *context, const char *name);
    void *get_proc_address_context;
} mpv_opengl_init_params;

typedef struct mpv_opengl_fbo {
    int fbo;
    int width;
    int height;
    int internal_format;
} mpv_opengl_fbo;

enum {
    MPV_EVENT_NONE = 0,
    MPV_EVENT_SHUTDOWN = 1,
    MPV_EVENT_COMMAND_REPLY = 5,
    MPV_EVENT_END_FILE = 7,
    MPV_EVENT_FILE_LOADED = 8,
    MPV_EVENT_PROPERTY_CHANGE = 22
};

enum {
    MPV_RENDER_PARAM_INVALID = 0,
    MPV_RENDER_PARAM_API_TYPE = 1,
    MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
    MPV_RENDER_PARAM_OPENGL_FBO = 3,
    MPV_RENDER_PARAM_FLIP_Y = 4,
    MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 12
};

typedef unsigned long (*fn_mpv_client_api_version)(void);
typedef const char *(*fn_mpv_error_string)(int);
typedef mpv_handle *(*fn_mpv_create)(void);
typedef int (*fn_mpv_initialize)(mpv_handle *);
typedef void (*fn_mpv_terminate_destroy)(mpv_handle *);
typedef int (*fn_mpv_set_option_string)(mpv_handle *, const char *, const char *);
typedef int (*fn_mpv_command_async)(mpv_handle *, uint64_t, const char *const *);
typedef int (*fn_mpv_set_property_async)(mpv_handle *, uint64_t, const char *, mpv_format, void *);
typedef int (*fn_mpv_get_property)(mpv_handle *, const char *, mpv_format, void *);
typedef void (*fn_mpv_free_node_contents)(mpv_node *);
typedef int (*fn_mpv_observe_property)(mpv_handle *, uint64_t, const char *, mpv_format);
typedef mpv_event *(*fn_mpv_wait_event)(mpv_handle *, double);
typedef void (*fn_mpv_set_wakeup_callback)(mpv_handle *, void (*)(void *), void *);
typedef int (*fn_mpv_render_context_create)(mpv_render_context **, mpv_handle *, mpv_render_param *);
typedef void (*fn_mpv_render_context_set_update_callback)(mpv_render_context *, void (*)(void *), void *);
typedef uint64_t (*fn_mpv_render_context_update)(mpv_render_context *);
typedef int (*fn_mpv_render_context_render)(mpv_render_context *, mpv_render_param *);
typedef void (*fn_mpv_render_context_report_swap)(mpv_render_context *);
typedef void (*fn_mpv_render_context_free)(mpv_render_context *);

struct MVPMPVPlayer {
    void *library;
    char library_path[512];
    mpv_handle *handle;
    mpv_render_context *render_context;
    uint64_t next_request_id;

    fn_mpv_client_api_version client_api_version;
    fn_mpv_error_string error_string;
    fn_mpv_create create;
    fn_mpv_initialize initialize;
    fn_mpv_terminate_destroy terminate_destroy;
    fn_mpv_set_option_string set_option_string;
    fn_mpv_command_async command_async;
    fn_mpv_set_property_async set_property_async;
    fn_mpv_get_property get_property;
    fn_mpv_free_node_contents free_node_contents;
    fn_mpv_observe_property observe_property;
    fn_mpv_wait_event wait_event;
    fn_mpv_set_wakeup_callback set_wakeup_callback;
    fn_mpv_render_context_create render_context_create;
    fn_mpv_render_context_set_update_callback render_context_set_update_callback;
    fn_mpv_render_context_update render_context_update;
    fn_mpv_render_context_render render_context_render;
    fn_mpv_render_context_report_swap render_context_report_swap;
    fn_mpv_render_context_free render_context_free;
};

static void write_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    snprintf(buffer, size, "%s", message == NULL ? "Unknown libmpv error" : message);
}

static void write_mpv_error(
    MVPMPVPlayer *player,
    char *buffer,
    size_t size,
    const char *operation,
    int code
) {
    const char *detail = player != NULL && player->error_string != NULL
        ? player->error_string(code)
        : "unknown error";
    if (buffer != NULL && size > 0) {
        snprintf(buffer, size, "%s: %s (%d)", operation, detail, code);
    }
}

static void *load_symbol(void *library, const char *name, char *error, size_t error_size) {
    dlerror();
    void *symbol = dlsym(library, name);
    const char *failure = dlerror();
    if (failure != NULL || symbol == NULL) {
        char message[512];
        snprintf(message, sizeof(message), "libmpv is missing required symbol %s", name);
        write_error(error, error_size, message);
        return NULL;
    }
    return symbol;
}

#define LOAD_REQUIRED(player, field, symbol_name) \
    do { \
        void *resolved = load_symbol((player)->library, symbol_name, error_buffer, error_buffer_size); \
        if (resolved == NULL) { goto failure; } \
        memcpy(&(player)->field, &resolved, sizeof(resolved)); \
    } while (0)

// Derives Contents/Frameworks/libmpv.2.dylib from the running executable's
// own path (Contents/MacOS/Owl), so a release build finds the copy
// scripts/bundle-mpv-deps.sh and the "Embed mpv runtime" build phase placed
// alongside it before ever looking at the Homebrew fallback paths.
static bool bundled_library_path(char *out, size_t out_size) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0 || size > PATH_MAX) {
        return false;
    }
    char raw[PATH_MAX];
    if (_NSGetExecutablePath(raw, &size) != 0) {
        return false;
    }
    char resolved[PATH_MAX];
    if (realpath(raw, resolved) == NULL) {
        return false;
    }

    char *macos_slash = strrchr(resolved, '/');
    if (macos_slash == NULL) {
        return false;
    }
    *macos_slash = '\0'; // ".../Owl.app/Contents/MacOS"

    char *contents_slash = strrchr(resolved, '/');
    if (contents_slash == NULL) {
        return false;
    }
    *contents_slash = '\0'; // ".../Owl.app/Contents"

    int written = snprintf(out, out_size, "%s/Frameworks/libmpv.2.dylib", resolved);
    return written > 0 && (size_t)written < out_size;
}

static void *open_libmpv(char *path, size_t path_size, char *error, size_t error_size) {
    const char *override_path = getenv("OWL_LIBMPV_PATH");
    if (override_path != NULL && override_path[0] != '\0') {
        dlerror();
        void *library = dlopen(override_path, RTLD_NOW | RTLD_LOCAL);
        if (library != NULL) {
            snprintf(path, path_size, "%s", override_path);
            return library;
        }
        const char *detail = dlerror();
        char message[768];
        snprintf(
            message,
            sizeof(message),
            "Could not load libmpv from OWL_LIBMPV_PATH (%s).%s%s",
            override_path,
            detail == NULL ? "" : "\n",
            detail == NULL ? "" : detail
        );
        write_error(error, error_size, message);
        return NULL;
    }

    char bundled[PATH_MAX];
    if (bundled_library_path(bundled, sizeof(bundled))) {
        dlerror();
        void *library = dlopen(bundled, RTLD_NOW | RTLD_LOCAL);
        if (library != NULL) {
            snprintf(path, path_size, "%s", bundled);
            return library;
        }
    }

    const char *candidates[] = {
        "/opt/homebrew/opt/mpv/lib/libmpv.2.dylib",
        "/opt/homebrew/lib/libmpv.2.dylib",
        "/opt/homebrew/lib/libmpv.dylib",
        NULL
    };

    for (int index = 0; candidates[index] != NULL; index++) {
        dlerror();
        void *library = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
        if (library != NULL) {
            snprintf(path, path_size, "%s", candidates[index]);
            return library;
        }
    }

    const char *detail = dlerror();
    char message[768];
    snprintf(
        message,
        sizeof(message),
        "Could not load Homebrew libmpv. Install it with `brew install mpv` and retry.%s%s",
        detail == NULL ? "" : "\n",
        detail == NULL ? "" : detail
    );
    write_error(error, error_size, message);
    return NULL;
}

MVPMPVPlayer *mvp_mpv_create(char *error_buffer, size_t error_buffer_size) {
    MVPMPVPlayer *player = calloc(1, sizeof(MVPMPVPlayer));
    if (player == NULL) {
        write_error(error_buffer, error_buffer_size, "Could not allocate the libmpv bridge.");
        return NULL;
    }

    player->library = open_libmpv(
        player->library_path,
        sizeof(player->library_path),
        error_buffer,
        error_buffer_size
    );
    if (player->library == NULL) {
        free(player);
        return NULL;
    }

    LOAD_REQUIRED(player, client_api_version, "mpv_client_api_version");
    LOAD_REQUIRED(player, error_string, "mpv_error_string");
    LOAD_REQUIRED(player, create, "mpv_create");
    LOAD_REQUIRED(player, initialize, "mpv_initialize");
    LOAD_REQUIRED(player, terminate_destroy, "mpv_terminate_destroy");
    LOAD_REQUIRED(player, set_option_string, "mpv_set_option_string");
    LOAD_REQUIRED(player, command_async, "mpv_command_async");
    LOAD_REQUIRED(player, set_property_async, "mpv_set_property_async");
    LOAD_REQUIRED(player, get_property, "mpv_get_property");
    LOAD_REQUIRED(player, free_node_contents, "mpv_free_node_contents");
    LOAD_REQUIRED(player, observe_property, "mpv_observe_property");
    LOAD_REQUIRED(player, wait_event, "mpv_wait_event");
    LOAD_REQUIRED(player, set_wakeup_callback, "mpv_set_wakeup_callback");
    LOAD_REQUIRED(player, render_context_create, "mpv_render_context_create");
    LOAD_REQUIRED(player, render_context_set_update_callback, "mpv_render_context_set_update_callback");
    LOAD_REQUIRED(player, render_context_update, "mpv_render_context_update");
    LOAD_REQUIRED(player, render_context_render, "mpv_render_context_render");
    LOAD_REQUIRED(player, render_context_report_swap, "mpv_render_context_report_swap");
    LOAD_REQUIRED(player, render_context_free, "mpv_render_context_free");

    unsigned long api_version = player->client_api_version();
    unsigned long major = api_version >> 16;
    if (major != 2) {
        char message[256];
        snprintf(
            message,
            sizeof(message),
            "Unsupported libmpv client API version %lu.%lu; major version 2 is required.",
            major,
            api_version & 0xffff
        );
        write_error(error_buffer, error_buffer_size, message);
        goto failure;
    }

    player->handle = player->create();
    if (player->handle == NULL) {
        write_error(error_buffer, error_buffer_size, "mpv_create returned no player handle.");
        goto failure;
    }

    player->set_option_string(player->handle, "terminal", "no");
    player->set_option_string(player->handle, "input-default-bindings", "no");
    player->set_option_string(player->handle, "input-vo-keyboard", "no");
    player->set_option_string(player->handle, "vo", "libmpv");
    player->set_option_string(player->handle, "hwdec", "auto-safe");
    player->set_option_string(player->handle, "keep-open", "yes");
    player->set_option_string(player->handle, "osc", "no");

    // Pick up sidecar subtitles next to the video. "fuzzy" takes Movie.en.srt
    // and Movie.forced.srt alongside Movie.mkv, where the default "exact" only
    // takes Movie.srt; sub-file-paths adds the subdirectory that a season of
    // downloads usually keeps them in. Which of the found tracks is shown, if
    // any, is left to mpv's own preference order.
    player->set_option_string(player->handle, "sub-auto", "fuzzy");
    player->set_option_string(player->handle, "sub-file-paths", "sub:subs:subtitles:Sub:Subs:Subtitles");

    // Show an embedded subtitle even when nothing marked it. mpv's own default
    // only falls back to tracks flagged "default", and Owl never sets
    // slang for a track to match by language instead, so a file whose one
    // English track carries no flag would open with no subtitle at all — not
    // what somebody who left "Show Subtitles Automatically" on is asking for.
    // Turning the preference off still sets sid to no, which this never
    // overrides.
    player->set_option_string(player->handle, "subs-fallback", "yes");

    // Owl provides its own UI. Disable mpv's LuaJIT-backed scripts so the
    // hardened app never attempts to execute unsigned generated code.
    player->set_option_string(player->handle, "load-scripts", "no");
    player->set_option_string(player->handle, "load-auto-profiles", "no");
    player->set_option_string(player->handle, "load-commands", "no");
    player->set_option_string(player->handle, "load-console", "no");
    player->set_option_string(player->handle, "load-context-menu", "no");
    player->set_option_string(player->handle, "load-positioning", "no");
    player->set_option_string(player->handle, "load-select", "no");
    player->set_option_string(player->handle, "load-stats-overlay", "no");
    player->set_option_string(player->handle, "ytdl", "no");

    int status = player->initialize(player->handle);
    if (status < 0) {
        write_mpv_error(player, error_buffer, error_buffer_size, "Could not initialize libmpv", status);
        goto failure;
    }

    player->next_request_id = 100;
    player->observe_property(player->handle, 1, "pause", MPV_FORMAT_FLAG);
    player->observe_property(player->handle, 2, "time-pos", MPV_FORMAT_DOUBLE);
    player->observe_property(player->handle, 3, "duration", MPV_FORMAT_DOUBLE);
    player->observe_property(player->handle, 4, "volume", MPV_FORMAT_DOUBLE);
    player->observe_property(player->handle, 5, "mute", MPV_FORMAT_FLAG);
    player->observe_property(player->handle, 6, "track-list", MPV_FORMAT_NONE);
    player->observe_property(player->handle, 7, "speed", MPV_FORMAT_DOUBLE);
    // keep-open holds mpv at the last frame instead of unloading at end of
    // file, and in that mode `end-file` is not a reliable signal of natural
    // end-of-playback; `eof-reached` is what the player itself flips.
    player->observe_property(player->handle, 8, "eof-reached", MPV_FORMAT_FLAG);
    player->observe_property(player->handle, 9, "sub-delay", MPV_FORMAT_DOUBLE);

    write_error(error_buffer, error_buffer_size, "");
    return player;

failure:
    if (player->handle != NULL && player->terminate_destroy != NULL) {
        player->terminate_destroy(player->handle);
    }
    if (player->library != NULL) {
        dlclose(player->library);
    }
    free(player);
    return NULL;
}

void mvp_mpv_destroy(MVPMPVPlayer *player) {
    if (player == NULL) {
        return;
    }
    mvp_mpv_destroy_renderer(player);
    if (player->handle != NULL) {
        player->set_wakeup_callback(player->handle, NULL, NULL);
        player->terminate_destroy(player->handle);
        player->handle = NULL;
    }
    if (player->library != NULL) {
        dlclose(player->library);
        player->library = NULL;
    }
    free(player);
}

uint64_t mvp_mpv_client_api_version(MVPMPVPlayer *player) {
    return player == NULL || player->client_api_version == NULL
        ? 0
        : player->client_api_version();
}

const char *mvp_mpv_library_path(MVPMPVPlayer *player) {
    return player == NULL ? NULL : player->library_path;
}

void mvp_mpv_set_wakeup_callback(
    MVPMPVPlayer *player,
    MVPMPVCallback callback,
    void *context
) {
    if (player != NULL && player->handle != NULL) {
        player->set_wakeup_callback(player->handle, callback, context);
    }
}

static void copy_text(char *destination, size_t size, const char *source) {
    if (destination == NULL || size == 0) {
        return;
    }
    snprintf(destination, size, "%s", source == NULL ? "" : source);
}

int mvp_mpv_poll_event(MVPMPVPlayer *player, MVPMPVEvent *output) {
    if (player == NULL || player->handle == NULL || output == NULL) {
        return 0;
    }

    memset(output, 0, sizeof(*output));
    mpv_event *event = player->wait_event(player->handle, 0);
    if (event == NULL || event->event_id == MPV_EVENT_NONE) {
        return 0;
    }

    if (event->event_id == MPV_EVENT_FILE_LOADED) {
        output->type = MVP_MPV_EVENT_FILE_LOADED;
        return 1;
    }

    if (event->event_id == MPV_EVENT_SHUTDOWN) {
        output->type = MVP_MPV_EVENT_SHUTDOWN;
        return 1;
    }

    if (event->event_id == MPV_EVENT_END_FILE) {
        mpv_event_end_file *end = event->data;
        output->type = MVP_MPV_EVENT_END_FILE;
        if (end != NULL) {
            output->end_reason = end->reason;
            output->error = end->error;
        }
        return 1;
    }

    if (event->event_id == MPV_EVENT_COMMAND_REPLY && event->error < 0) {
        output->type = MVP_MPV_EVENT_COMMAND_ERROR;
        output->error = event->error;
        copy_text(
            output->string_value,
            sizeof(output->string_value),
            player->error_string(event->error)
        );
        return 1;
    }

    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
        mpv_event_property *property = event->data;
        if (property == NULL || property->name == NULL) {
            return 1;
        }
        if (strcmp(property->name, "track-list") == 0) {
            output->type = MVP_MPV_EVENT_TRACKS_CHANGED;
            return 1;
        }

        output->type = MVP_MPV_EVENT_PROPERTY;
        copy_text(output->name, sizeof(output->name), property->name);
        if (property->format == MPV_FORMAT_FLAG && property->data != NULL) {
            output->value_type = MVP_MPV_VALUE_FLAG;
            output->flag_value = *(int *)property->data;
        } else if (property->format == MPV_FORMAT_DOUBLE && property->data != NULL) {
            output->value_type = MVP_MPV_VALUE_DOUBLE;
            output->double_value = *(double *)property->data;
        } else if (property->format == MPV_FORMAT_STRING && property->data != NULL) {
            output->value_type = MVP_MPV_VALUE_STRING;
            copy_text(
                output->string_value,
                sizeof(output->string_value),
                *(char **)property->data
            );
        }
        return 1;
    }

    return 1;
}

int mvp_mpv_command_async(
    MVPMPVPlayer *player,
    const char *const arguments[],
    char *error_buffer,
    size_t error_buffer_size
) {
    if (player == NULL || player->handle == NULL || arguments == NULL) {
        write_error(error_buffer, error_buffer_size, "The libmpv player is unavailable.");
        return -1;
    }
    int status = player->command_async(player->handle, player->next_request_id++, arguments);
    if (status < 0) {
        write_mpv_error(player, error_buffer, error_buffer_size, "mpv command failed", status);
    }
    return status;
}

int mvp_mpv_set_flag_async(
    MVPMPVPlayer *player,
    const char *property,
    bool value,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (player == NULL || player->handle == NULL) {
        write_error(error_buffer, error_buffer_size, "The libmpv player is unavailable.");
        return -1;
    }
    int flag = value ? 1 : 0;
    int status = player->set_property_async(
        player->handle,
        player->next_request_id++,
        property,
        MPV_FORMAT_FLAG,
        &flag
    );
    if (status < 0) {
        write_mpv_error(player, error_buffer, error_buffer_size, "Could not set mpv property", status);
    }
    return status;
}

int mvp_mpv_set_double_async(
    MVPMPVPlayer *player,
    const char *property,
    double value,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (player == NULL || player->handle == NULL) {
        write_error(error_buffer, error_buffer_size, "The libmpv player is unavailable.");
        return -1;
    }
    int status = player->set_property_async(
        player->handle,
        player->next_request_id++,
        property,
        MPV_FORMAT_DOUBLE,
        &value
    );
    if (status < 0) {
        write_mpv_error(player, error_buffer, error_buffer_size, "Could not set mpv property", status);
    }
    return status;
}

int mvp_mpv_initialize_renderer(
    MVPMPVPlayer *player,
    MVPMPVGetProcAddress get_proc_address,
    void *get_proc_address_context,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (player == NULL || player->handle == NULL || get_proc_address == NULL) {
        write_error(error_buffer, error_buffer_size, "Cannot initialize the libmpv renderer.");
        return -1;
    }
    if (player->render_context != NULL) {
        return 0;
    }

    const char *api_type = "opengl";
    mpv_opengl_init_params gl_init = {
        .get_proc_address = get_proc_address,
        .get_proc_address_context = get_proc_address_context
    };
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)api_type },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };

    int status = player->render_context_create(
        &player->render_context,
        player->handle,
        parameters
    );
    if (status < 0) {
        write_mpv_error(player, error_buffer, error_buffer_size, "Could not create the mpv renderer", status);
    }
    return status;
}

void mvp_mpv_set_render_update_callback(
    MVPMPVPlayer *player,
    MVPMPVCallback callback,
    void *context
) {
    if (player != NULL && player->render_context != NULL) {
        player->render_context_set_update_callback(player->render_context, callback, context);
    }
}

int mvp_mpv_render(
    MVPMPVPlayer *player,
    int framebuffer,
    int width,
    int height,
    bool flip_y
) {
    if (player == NULL || player->render_context == NULL || width <= 0 || height <= 0) {
        return -1;
    }
    player->render_context_update(player->render_context);
    mpv_opengl_fbo fbo = {
        .fbo = framebuffer,
        .width = width,
        .height = height,
        .internal_format = 0
    };
    int flip = flip_y ? 1 : 0;
    // The render worker should not wait for mpv's target presentation time;
    // AppKit and the update callback schedule the next draw.
    int block_for_target_time = 0;
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    return player->render_context_render(player->render_context, parameters);
}

void mvp_mpv_report_swap(MVPMPVPlayer *player) {
    if (player != NULL && player->render_context != NULL) {
        player->render_context_report_swap(player->render_context);
    }
}

void mvp_mpv_destroy_renderer(MVPMPVPlayer *player) {
    if (player == NULL || player->render_context == NULL) {
        return;
    }
    player->render_context_set_update_callback(player->render_context, NULL, NULL);
    player->render_context_free(player->render_context);
    player->render_context = NULL;
}

static mpv_node *map_value(mpv_node *node, const char *key) {
    if (node == NULL || node->format != MPV_FORMAT_NODE_MAP || node->value.list == NULL) {
        return NULL;
    }
    mpv_node_list *list = node->value.list;
    for (int index = 0; index < list->num; index++) {
        if (list->keys[index] != NULL && strcmp(list->keys[index], key) == 0) {
            return &list->values[index];
        }
    }
    return NULL;
}

static bool node_string_equals(mpv_node *node, const char *value) {
    return node != NULL
        && node->format == MPV_FORMAT_STRING
        && node->value.string != NULL
        && strcmp(node->value.string, value) == 0;
}

static const char *node_string(mpv_node *node) {
    return node != NULL && node->format == MPV_FORMAT_STRING
        ? node->value.string
        : NULL;
}

static bool node_flag(mpv_node *node) {
    return node != NULL && node->format == MPV_FORMAT_FLAG && node->value.flag != 0;
}

static int64_t node_int64(mpv_node *node) {
    return node != NULL && node->format == MPV_FORMAT_INT64 ? node->value.int64 : 0;
}

int mvp_mpv_copy_subtitle_tracks(
    MVPMPVPlayer *player,
    MVPMPVSubtitleTrack *tracks,
    int capacity
) {
    if (player == NULL || player->handle == NULL) {
        return -1;
    }

    mpv_node track_list = {0};
    int status = player->get_property(
        player->handle,
        "track-list",
        MPV_FORMAT_NODE,
        &track_list
    );
    if (status < 0) {
        return status;
    }

    int count = 0;
    if (track_list.format == MPV_FORMAT_NODE_ARRAY && track_list.value.list != NULL) {
        mpv_node_list *items = track_list.value.list;
        for (int index = 0; index < items->num; index++) {
            mpv_node *item = &items->values[index];
            if (!node_string_equals(map_value(item, "type"), "sub")) {
                continue;
            }
            if (tracks != NULL && count < capacity) {
                MVPMPVSubtitleTrack *track = &tracks[count];
                memset(track, 0, sizeof(*track));
                track->id = node_int64(map_value(item, "id"));
                track->selected = node_flag(map_value(item, "selected"));
                track->external = node_flag(map_value(item, "external"));
                copy_text(track->title, sizeof(track->title), node_string(map_value(item, "title")));
                copy_text(track->language, sizeof(track->language), node_string(map_value(item, "lang")));
                copy_text(track->codec, sizeof(track->codec), node_string(map_value(item, "codec")));
            }
            count++;
        }
    }

    player->free_node_contents(&track_list);
    return count;
}

int mvp_mpv_copy_audio_tracks(
    MVPMPVPlayer *player,
    MVPMPVAudioTrack *tracks,
    int capacity
) {
    if (player == NULL || player->handle == NULL) {
        return -1;
    }

    mpv_node track_list = {0};
    int status = player->get_property(
        player->handle,
        "track-list",
        MPV_FORMAT_NODE,
        &track_list
    );
    if (status < 0) {
        return status;
    }

    int count = 0;
    if (track_list.format == MPV_FORMAT_NODE_ARRAY && track_list.value.list != NULL) {
        mpv_node_list *items = track_list.value.list;
        for (int index = 0; index < items->num; index++) {
            mpv_node *item = &items->values[index];
            if (!node_string_equals(map_value(item, "type"), "audio")) {
                continue;
            }
            if (tracks != NULL && count < capacity) {
                MVPMPVAudioTrack *track = &tracks[count];
                memset(track, 0, sizeof(*track));
                track->id = node_int64(map_value(item, "id"));
                track->selected = node_flag(map_value(item, "selected"));
                track->external = node_flag(map_value(item, "external"));
                copy_text(track->title, sizeof(track->title), node_string(map_value(item, "title")));
                copy_text(track->language, sizeof(track->language), node_string(map_value(item, "lang")));
                copy_text(track->codec, sizeof(track->codec), node_string(map_value(item, "codec")));
            }
            count++;
        }
    }

    player->free_node_contents(&track_list);
    return count;
}
