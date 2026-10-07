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
    MVP_MPV_EVENT_TRACKS_CHANGED = 6,
    MVP_MPV_EVENT_CHAPTERS_CHANGED = 7,
    // A command finished without error. Failures are COMMAND_ERROR; both carry
    // the request id the command was sent with in `reply_id`.
    MVP_MPV_EVENT_COMMAND_REPLY = 8
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
    uint64_t reply_id;
    double double_value;
    char name[64];
    char string_value[512];
} MVPMPVEvent;

typedef struct MVPMPVSubtitleTrack {
    int64_t id;
    // The track shown as the subtitle. A track shown as the second subtitle
    // is `secondary` instead: mpv marks both "selected" in its track list.
    bool selected;
    bool secondary;
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

typedef struct MVPMPVChapter {
    double time;
    char title[256];
} MVPMPVChapter;

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

// `request_id`, when given, receives the id the command's reply will carry.
int mvp_mpv_command_async(
    MVPMPVPlayer *player,
    const char *const arguments[],
    uint64_t *request_id,
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
// Returns 1 after rendering, 0 when no frame needs drawing, or a negative error.
int mvp_mpv_render(
    MVPMPVPlayer *player,
    int framebuffer,
    int width,
    int height,
    bool flip_y,
    bool force_redraw
);
// How long until the next frame is due on screen, for the caller to wait out
// before mvp_mpv_render, which no longer waits itself. Like every mvp_mpv
// render call, it needs the OpenGL context current and no other render call
// running.
int64_t mvp_mpv_microseconds_until_next_frame(MVPMPVPlayer *player);
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

// The file's chapters in order, the way the track copies work: called with no
// buffer it returns how many there are.
int mvp_mpv_copy_chapters(
    MVPMPVPlayer *player,
    MVPMPVChapter *chapters,
    int capacity
);

#ifdef __cplusplus
}
#endif

#endif
