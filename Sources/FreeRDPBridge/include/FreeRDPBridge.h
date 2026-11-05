// A small C API over FreeRDP 3 for RDP Manager. Swift sees only these types; every FreeRDP
// structure stays inside bridge.c. One rm_session is one connection attempt.
#ifndef RDPMANAGER_FREERDP_BRIDGE_H
#define RDPMANAGER_FREERDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rm_session rm_session;

typedef enum {
    RM_SECURITY_AUTO = 0, // Negotiate NLA, TLS or Standard RDP Security, strongest first.
    RM_SECURITY_NLA = 1,
    RM_SECURITY_TLS = 2,
    RM_SECURITY_RDP = 3 // Standard RDP Security (RC4, no server authentication).
} rm_security;

typedef enum {
    RM_AUTH_NEGOTIATE = 0, // Kerberos when available, else NTLM.
    RM_AUTH_KERBEROS = 1,  // Kerberos only.
    RM_AUTH_NTLM = 2       // NTLM only.
} rm_auth_package;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username; // may be NULL
    const char *domain;   // may be NULL
    const char *password; // may be NULL; never logged
    uint32_t width;
    uint32_t height;
    uint32_t desktop_scale; // percent, 100…500
    uint32_t device_scale;  // 100, 140 or 180
    uint32_t keyboard_layout; // Windows KLID
    uint32_t timeout_ms;
    const char *client_name;

    rm_security security;
    rm_auth_package auth_package;
    const char *kerberos_realm;  // optional
    const char *kerberos_kdc_url; // optional KDC proxy URL

    bool clipboard;
    bool audio_playback;
    bool microphone;
    bool printers;      // every CUPS printer on this Mac
    bool smartcards;    // every PC/SC reader (YubiKey PIV, smart cards)
    const char *usb_devices; // "VID:PID#VID:PID" in hex, or NULL
    const char *drive_name;  // shown as \\tsclient\<name>; NULL for none
    const char *drive_path;
} rm_config;

/// Why the bridge itself ended a session (FreeRDP's error codes cover the rest).
typedef enum {
    RM_FAILURE_NONE = 0,
    RM_FAILURE_DESKTOP_TOO_LARGE = 1 // the server chose a desktop beyond the limits below
} rm_failure;

/// The largest desktop a server may choose: 8192 pixels a side and about 37.7 million pixels
/// (8192 × 4608, 151 MB of BGRA). Larger sizes end the session before any framebuffer exists.
enum {
    RM_MAX_DESKTOP_SIDE = 8192,
    RM_MAX_DESKTOP_PIXELS = 8192 * 4608
};

/// What a certificate callback decides. Rejecting closes the connection before any credential
/// is sent over TLS.
typedef enum {
    RM_CERT_REJECT = 0,
    RM_CERT_ACCEPT_ONCE = 2
} rm_cert_decision;

typedef struct {
    void *context;
    /// The framebuffer changed in (x, y, w, h). `pixels` is BGRA, valid only during the call.
    void (*on_frame)(void *context, const uint8_t *pixels, uint32_t width, uint32_t height,
                     uint32_t stride, int32_t x, int32_t y, int32_t w, int32_t h);
    /// Connected at this desktop size. `selected_protocol` is the negotiated security
    /// ([MS-RDPBCGR] 2.2.1.2.1): 0 Standard RDP Security, 1 TLS, 2 or 8 NLA (CredSSP).
    void (*on_connected)(void *context, uint32_t width, uint32_t height, uint32_t selected_protocol);
    /// During TLS. `pem` is the server certificate in PEM. `changed` when FreeRDP knows the
    /// host with another certificate (unused: RDP Manager keeps its own trust store).
    rm_cert_decision (*on_certificate)(void *context, const char *host, uint16_t port,
                                       const char *subject, const char *issuer, const char *pem,
                                       bool changed);
    /// A remote pointer shape (BGRA premultiplied, top-down) or NULL pixels for the system
    /// arrow; `hidden` for no pointer.
    void (*on_pointer)(void *context, const uint8_t *pixels, uint32_t width, uint32_t height,
                       uint32_t hot_x, uint32_t hot_y, bool hidden);
    /// Text the server copied (UTF-8).
    void (*on_remote_clipboard_text)(void *context, const char *utf8);
    /// The connection ended. `last_error` is FreeRDP's last error code, `error_info` the
    /// server's Set Error Info code ([MS-RDPBCGR] 2.2.5.1.1); both 0 for a clean end.
    /// `failure` is set when the bridge ended it.
    void (*on_ended)(void *context, uint32_t last_error, uint32_t error_info, rm_failure failure);
} rm_callbacks;

rm_session *rm_session_new(const rm_config *config, const rm_callbacks *callbacks);
/// Connects and runs the session until it ends. Blocks; call on a dedicated thread.
void rm_session_run(rm_session *session);
/// Ends the connection from any thread. `rm_session_run` returns soon after.
void rm_session_cancel(rm_session *session);
/// After `rm_session_run` returned.
void rm_session_free(rm_session *session);

// Input, from any thread while connected. Coordinates are desktop pixels.
void rm_session_send_mac_key(rm_session *session, uint16_t mac_key_code, bool down);
void rm_session_send_scancode(rm_session *session, uint16_t scancode, bool extended, bool down);
void rm_session_send_unicode(rm_session *session, uint16_t code_unit, bool down);
void rm_session_send_pointer(rm_session *session, uint16_t flags, uint16_t x, uint16_t y);
/// Pointer flags, as [MS-RDPBCGR] TS_POINTER_EVENT.
enum {
    RM_PTR_MOVE = 0x0800,
    RM_PTR_DOWN = 0x8000,
    RM_PTR_BUTTON1 = 0x1000,
    RM_PTR_BUTTON2 = 0x2000,
    RM_PTR_BUTTON3 = 0x4000,
    RM_PTR_WHEEL = 0x0200,
    RM_PTR_HWHEEL = 0x0400,
    RM_PTR_WHEEL_NEGATIVE = 0x0100
};
/// Asks the server to resize the desktop through Display Control. Returns false when the
/// channel is not (yet) available.
bool rm_session_resize(rm_session *session, uint32_t width, uint32_t height, uint32_t desktop_scale,
                       uint32_t device_scale);
/// Offers text to the server's clipboard. Ignored while clipboard sharing is off.
void rm_session_set_local_clipboard_text(rm_session *session, const char *utf8);
/// The live Share Clipboard switch. Turning it off forgets the offered Mac text, withdraws
/// the offer and refuses the server's later requests; remote text is no longer fetched.
void rm_session_set_clipboard_shared(rm_session *session, bool shared);
/// Whether the server could fetch Mac text right now (for tests).
bool rm_session_offers_clipboard_text(rm_session *session);
/// Whether a desktop of this size is within RM_MAX_DESKTOP_SIDE and RM_MAX_DESKTOP_PIXELS.
bool rm_desktop_size_is_allowed(uint32_t width, uint32_t height);

/// FreeRDP's description of an error code, for diagnostics.
const char *rm_error_name(uint32_t last_error);
const char *rm_error_info_string(uint32_t error_info);

#ifdef __cplusplus
}
#endif

#endif
