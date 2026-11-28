#ifndef C_SPICE_BRIDGE_H
#define C_SPICE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SFSession SFSession;
typedef struct {
 const char *host, *port, *tls_port, *password, *ca_file, *ca_pem, *subject, *proxy;
 int insecure, clipboard, audio;
} SFConfig;
enum { SF_STATE=1, SF_FRAME, SF_CURSOR, SF_AGENT, SF_MOUSE, SF_CLIPBOARD, SF_AUDIO_START, SF_AUDIO_DATA, SF_AUDIO_STOP, SF_DESTROYED, SF_ERROR, SF_CLEAR, SF_DIRTY };
/* SF_DIRTY (a=x, b=y, c=width, d=height) precedes each SF_FRAME with the region changed since the previous frame. */
/* Data is borrowed for this call only. Frames are tightly packed BGRX8 (alpha must be ignored). */
typedef void (*SFCallback)(void *context, int event, int a, int b, int c, int d, const uint8_t *data, size_t size);
SFSession *sf_session_create(const SFConfig *config, SFCallback callback, void *context);
void sf_session_destroy(SFSession *session);
void sf_key(SFSession *, uint32_t code, int pressed);
void sf_pointer(SFSession *, int x, int y, int buttons, int relative);
void sf_button(SFSession *, int button, int pressed, int buttons);
void sf_release_keys(SFSession *);
void sf_resolution(SFSession *, int width, int height);
void sf_clipboard(SFSession *, const uint8_t *text, size_t size);
const char *sf_backend_version(void);
#ifdef __cplusplus
}
#endif
#endif
