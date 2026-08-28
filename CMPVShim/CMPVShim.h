#ifndef CMPVShim_h
#define CMPVShim_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVPMPVPlayer MVPMPVPlayer;

typedef enum MVPMPVEventType {
    MVP_MPV_EVENT_NONE = 0,
    MVP_MPV_EVENT_PROPERTY = 1,
    MVP_MPV_EVENT_FILE_LOADED = 2,
    MVP_MPV_EVENT_END_FILE = 3,
    MVP_MPV_EVENT_SHUTDOWN = 4,
    MVP_MPV_EVENT_COMMAND_ERROR = 5,
    MVP_MPV_EVENT_TRACKS_CHANGED = 6
} MVPMPVEventType;

typedef enum MVPMPVValueType {
    MVP_MPV_VALUE_NONE = 0,
    MVP_MPV_VALUE_FLAG = 1,
    MVP_MPV_VALUE_DOUBLE = 2,
    MVP_MPV_VALUE_STRING = 3
} MVPMPVValueType;

typedef struct MVPMPVEvent {
    MVPMPVEventType type;
    MVPMPVValueType value_type;
    int error;
    int end_reason;
    int flag_value;
    double double_value;
    char name[64];
    char string_value[512];
} MVPMPVEvent;

typedef struct MVPMPVSubtitleTrack {
    int64_t id;
    bool selected;
    bool external;
    char title[256];
    char language[64];
    char codec[64];
    // Where an external track was loaded from, empty for an embedded one.
    // PATH_MAX so a path is never half-copied: the app matches tracks against
    // it, and a truncated path matches nothing.
    char external_filename[1024];
} MVPMPVSubtitleTrack;

typedef struct MVPMPVAudioTrack {
    int64_t id;
    bool selected;
    bool external;
    char title[256];
    char language[64];
    char codec[64];
} MVPMPVAudioTrack;

typedef void (*MVPMPVCallback)(void *context);
typedef void *(*MVPMPVGetProcAddress)(void *context, const char *name);

MVPMPVPlayer *mvp_mpv_create(char *error_buffer, size_t error_buffer_size);
void mvp_mpv_destroy(MVPMPVPlayer *player);
uint64_t mvp_mpv_client_api_version(MVPMPVPlayer *player);
const char *mvp_mpv_library_path(MVPMPVPlayer *player);

void mvp_mpv_set_wakeup_callback(
    MVPMPVPlayer *player,
    MVPMPVCallback callback,
    void *context
);
int mvp_mpv_poll_event(MVPMPVPlayer *player, MVPMPVEvent *event);

int mvp_mpv_command_async(
    MVPMPVPlayer *player,
    const char *const arguments[],
    char *error_buffer,
    size_t error_buffer_size
);
int mvp_mpv_set_flag_async(
    MVPMPVPlayer *player,
    const char *property,
    bool value,
    char *error_buffer,
    size_t error_buffer_size
);
int mvp_mpv_set_double_async(
    MVPMPVPlayer *player,
    const char *property,
    double value,
    char *error_buffer,
    size_t error_buffer_size
);

int mvp_mpv_initialize_renderer(
    MVPMPVPlayer *player,
    MVPMPVGetProcAddress get_proc_address,
    void *get_proc_address_context,
    char *error_buffer,
    size_t error_buffer_size
);
void mvp_mpv_set_render_update_callback(
    MVPMPVPlayer *player,
    MVPMPVCallback callback,
    void *context
);
int mvp_mpv_render(
    MVPMPVPlayer *player,
    int framebuffer,
    int width,
    int height,
    bool flip_y
);
void mvp_mpv_report_swap(MVPMPVPlayer *player);
void mvp_mpv_destroy_renderer(MVPMPVPlayer *player);

int mvp_mpv_copy_subtitle_tracks(
    MVPMPVPlayer *player,
    MVPMPVSubtitleTrack *tracks,
    int capacity
);

int mvp_mpv_copy_audio_tracks(
    MVPMPVPlayer *player,
    MVPMPVAudioTrack *tracks,
    int capacity
);

#ifdef __cplusplus
}
#endif

#endif
