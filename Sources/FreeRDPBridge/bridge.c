// FreeRDP 3 client for RDP Manager: connection, GDI framebuffer, input, display control,
// text clipboard, pointer shapes and device redirection settings. Modeled on FreeRDP's sample
// client (client/Sample) and SDL client.
#include "FreeRDPBridge.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/constants.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/utils/helpers.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpgfx.h>
#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <winpr/wlog.h>

struct rm_session {
    rdpContext *context;
    rm_callbacks callbacks;
    // Guards connected, disp, cliprdr, clipboard_shared and local_clipboard. Recursive: a
    // channel write can close its channel on the calling thread, which publishes the
    // disconnect event that takes this lock again.
    //
    // Channel pointers are used only while this lock is held. FreeRDP publishes the channel's
    // disconnected or terminated event (whose handlers clear the pointer under this lock)
    // before it frees the channel, so a holder of the lock never sees a freed channel.
    pthread_mutex_t lock;
    bool connected;
    DispClientContext *disp;
    CliprdrClientContext *cliprdr;
    bool clipboard_shared;  // the user's live Share Clipboard switch
    char *local_clipboard;  // UTF-8 text offered to the server; NULL when not shared
    rm_security requested_security;
    uint32_t requested_format;
    rm_failure failure;     // why the bridge itself ended the session
    pcRdpgfxCreateSurface gfx_create_surface; // FreeRDP GDI's, wrapped by rm_gfx_create_surface
};

/// Records the first reason the bridge ends the session, for on_ended.
static void rm_fail(rm_session *session, rm_failure failure) {
    if (!session)
        return;
    pthread_mutex_lock(&session->lock);
    if (session->failure == RM_FAILURE_NONE)
        session->failure = failure;
    pthread_mutex_unlock(&session->lock);
}

/// Server-chosen desktop sizes are bounded before any framebuffer is allocated: FreeRDP takes
/// 16-bit sizes from the server (up to 17 GB of BGRA), and the app copies the framebuffer.
static bool rm_desktop_size_allowed(UINT32 width, UINT32 height) {
    return width > 0 && height > 0 && width <= RM_MAX_DESKTOP_SIDE && height <= RM_MAX_DESKTOP_SIDE &&
           (uint64_t)width * height <= RM_MAX_DESKTOP_PIXELS;
}

typedef struct {
    rdpClientContext common;
    rm_session *owner;
} rm_context;

typedef struct {
    rdpPointer pointer;
    uint8_t *pixels;
} rm_pointer;

static rm_session *owner_of(rdpContext *context) {
    return context ? ((rm_context *)context)->owner : NULL;
}

// MARK: - Painting

static BOOL rm_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd && gdi->primary->hdc->hwnd->invalid)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL rm_end_paint(rdpContext *context) {
    rm_session *session = owner_of(context);
    rdpGdi *gdi = context->gdi;
    if (!session || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;
    HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
    if (!invalid || invalid->null)
        return TRUE;
    if (session->callbacks.on_frame)
        session->callbacks.on_frame(session->callbacks.context, gdi->primary_buffer, gdi->width, gdi->height,
                                    gdi->stride, invalid->x, invalid->y, invalid->w, invalid->h);
    return TRUE;
}

static BOOL rm_desktop_resize(rdpContext *context) {
    rdpSettings *settings = context->settings;
    rdpGdi *gdi = context->gdi;
    const UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    rm_session *session = owner_of(context);
    if (!rm_desktop_size_allowed(width, height)) {
        rm_fail(session, RM_FAILURE_DESKTOP_TOO_LARGE);
        return FALSE;
    }
    if (!gdi_resize(gdi, width, height))
        return FALSE;
    // The whole new surface is the dirty region.
    if (session && session->callbacks.on_frame)
        session->callbacks.on_frame(session->callbacks.context, gdi->primary_buffer, gdi->width, gdi->height,
                                    gdi->stride, 0, 0, (int32_t)gdi->width, (int32_t)gdi->height);
    return TRUE;
}

// MARK: - Pointer

static BOOL rm_pointer_new(rdpContext *context, rdpPointer *pointer) {
    rm_pointer *ptr = (rm_pointer *)pointer;
    const size_t size = (size_t)pointer->width * pointer->height * 4;
    if (size == 0)
        return TRUE;
    ptr->pixels = calloc(1, size);
    if (!ptr->pixels)
        return FALSE;
    if (!freerdp_image_copy_from_pointer_data(ptr->pixels, PIXEL_FORMAT_BGRA32, pointer->width * 4, 0, 0,
                                              pointer->width, pointer->height, pointer->xorMaskData,
                                              pointer->lengthXorMask, pointer->andMaskData,
                                              pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette)) {
        free(ptr->pixels);
        ptr->pixels = NULL;
        return FALSE;
    }
    return TRUE;
}

static void rm_pointer_free(rdpContext *context, rdpPointer *pointer) {
    WINPR_UNUSED(context);
    rm_pointer *ptr = (rm_pointer *)pointer;
    free(ptr->pixels);
    ptr->pixels = NULL;
}

static BOOL rm_pointer_set(rdpContext *context, rdpPointer *pointer) {
    rm_session *session = owner_of(context);
    rm_pointer *ptr = (rm_pointer *)pointer;
    if (session && session->callbacks.on_pointer)
        session->callbacks.on_pointer(session->callbacks.context, ptr->pixels, pointer->width, pointer->height,
                                      pointer->xPos, pointer->yPos, false);
    return TRUE;
}

static BOOL rm_pointer_set_null(rdpContext *context) {
    rm_session *session = owner_of(context);
    if (session && session->callbacks.on_pointer)
        session->callbacks.on_pointer(session->callbacks.context, NULL, 0, 0, 0, 0, true);
    return TRUE;
}

static BOOL rm_pointer_set_default(rdpContext *context) {
    rm_session *session = owner_of(context);
    if (session && session->callbacks.on_pointer)
        session->callbacks.on_pointer(session->callbacks.context, NULL, 0, 0, 0, 0, false);
    return TRUE;
}

static BOOL rm_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    WINPR_UNUSED(context);
    WINPR_UNUSED(x);
    WINPR_UNUSED(y);
    return TRUE; // The Mac owns the pointer; a server warp is ignored.
}

// MARK: - Clipboard (text)

static UINT rm_cliprdr_send_format_list(CliprdrClientContext *cliprdr, bool has_text) {
    CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT, .formatName = NULL };
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = has_text ? 1 : 0;
    list.formats = has_text ? &format : NULL;
    return cliprdr->ClientFormatList(cliprdr, &list);
}

static UINT rm_cliprdr_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    WINPR_UNUSED(ready);
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
    if (rc != CHANNEL_RC_OK)
        return rc;
    rm_session *session = cliprdr->custom;
    pthread_mutex_lock(&session->lock);
    const bool has_text = session->clipboard_shared && session->local_clipboard != NULL;
    pthread_mutex_unlock(&session->lock);
    return rm_cliprdr_send_format_list(cliprdr, has_text);
}

static UINT rm_cliprdr_server_capabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *caps) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(caps);
    return CHANNEL_RC_OK;
}

static UINT rm_cliprdr_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    if (rc != CHANNEL_RC_OK)
        return rc;
    rm_session *session = cliprdr->custom;
    pthread_mutex_lock(&session->lock);
    const bool shared = session->clipboard_shared;
    pthread_mutex_unlock(&session->lock);
    if (!shared)
        return CHANNEL_RC_OK; // not fetched while sharing is off
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT) {
            session->requested_format = CF_UNICODETEXT;
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.requestedFormatId = CF_UNICODETEXT;
            return cliprdr->ClientFormatDataRequest(cliprdr, &request);
        }
    }
    return CHANNEL_RC_OK;
}

static UINT rm_cliprdr_server_format_list_response(CliprdrClientContext *cliprdr,
                                                   const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    WINPR_UNUSED(cliprdr);
    WINPR_UNUSED(response);
    return CHANNEL_RC_OK;
}

static UINT rm_cliprdr_server_format_data_request(CliprdrClientContext *cliprdr,
                                                  const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    rm_session *session = cliprdr->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    WCHAR *wide = NULL;
    size_t wide_chars = 0;
    pthread_mutex_lock(&session->lock);
    if (request->requestedFormatId == CF_UNICODETEXT && session->clipboard_shared && session->local_clipboard)
        wide = ConvertUtf8ToWCharAlloc(session->local_clipboard, &wide_chars);
    pthread_mutex_unlock(&session->lock);
    if (wide) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)((wide_chars + 1) * sizeof(WCHAR));
        response.requestedFormatData = (const BYTE *)wide;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(wide);
    return rc;
}

static UINT rm_cliprdr_server_format_data_response(CliprdrClientContext *cliprdr,
                                                   const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    rm_session *session = cliprdr->custom;
    pthread_mutex_lock(&session->lock);
    const bool shared = session->clipboard_shared;
    pthread_mutex_unlock(&session->lock);
    if (!shared || response->common.msgFlags != CB_RESPONSE_OK || session->requested_format != CF_UNICODETEXT ||
        !response->requestedFormatData || response->common.dataLen < sizeof(WCHAR))
        return CHANNEL_RC_OK;
    const size_t chars = response->common.dataLen / sizeof(WCHAR);
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData, chars, NULL);
    if (utf8 && session->callbacks.on_remote_clipboard_text)
        session->callbacks.on_remote_clipboard_text(session->callbacks.context, utf8);
    free(utf8);
    return CHANNEL_RC_OK;
}

// MARK: - Channels

/// The graphics pipeline allocates every surface the server creates; bound them like the
/// desktop.
static UINT rm_gfx_create_surface(RdpgfxClientContext *gfx, const RDPGFX_CREATE_SURFACE_PDU *create) {
    rdpGdi *gdi = gfx ? (rdpGdi *)gfx->custom : NULL;
    rm_session *session = gdi ? owner_of(gdi->context) : NULL;
    if (!session || !session->gfx_create_surface)
        return ERROR_INTERNAL_ERROR;
    if (!rm_desktop_size_allowed(create->width, create->height)) {
        rm_fail(session, RM_FAILURE_DESKTOP_TOO_LARGE);
        return ERROR_INVALID_DATA; // the surface is refused and never allocated
    }
    return session->gfx_create_surface(gfx, create);
}

static void rm_on_channel_connected(void *ctx, const ChannelConnectedEventArgs *e) {
    rdpContext *context = ctx;
    rm_session *session = owner_of(context);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&session->lock);
        session->disp = (DispClientContext *)e->pInterface;
        pthread_mutex_unlock(&session->lock);
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *cliprdr = (CliprdrClientContext *)e->pInterface;
        cliprdr->custom = session;
        cliprdr->MonitorReady = rm_cliprdr_monitor_ready;
        cliprdr->ServerCapabilities = rm_cliprdr_server_capabilities;
        cliprdr->ServerFormatList = rm_cliprdr_server_format_list;
        cliprdr->ServerFormatListResponse = rm_cliprdr_server_format_list_response;
        cliprdr->ServerFormatDataRequest = rm_cliprdr_server_format_data_request;
        cliprdr->ServerFormatDataResponse = rm_cliprdr_server_format_data_response;
        pthread_mutex_lock(&session->lock);
        session->cliprdr = cliprdr;
        pthread_mutex_unlock(&session->lock);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, e);
        if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
            // FreeRDP's handler has just set up the GDI pipeline callbacks.
            RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
            if (gfx && gfx->CreateSurface && gfx->CreateSurface != rm_gfx_create_surface) {
                session->gfx_create_surface = gfx->CreateSurface;
                gfx->CreateSurface = rm_gfx_create_surface;
            }
        }
    }
}

/// Forgets a channel before FreeRDP frees it. Taking the lock also waits for any call that
/// is using the channel right now (see rm_session.lock).
static bool rm_forget_channel(rm_session *session, const char *name) {
    if (strcmp(name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&session->lock);
        session->disp = NULL;
        pthread_mutex_unlock(&session->lock);
        return true;
    }
    if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&session->lock);
        session->cliprdr = NULL;
        pthread_mutex_unlock(&session->lock);
        return true;
    }
    return false;
}

static void rm_on_channel_disconnected(void *ctx, const ChannelDisconnectedEventArgs *e) {
    rdpContext *context = ctx;
    if (!rm_forget_channel(owner_of(context), e->name))
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

// A dynamic channel can be freed without a disconnected event first.
static void rm_on_channel_terminated(void *ctx, const ChannelTerminatedEventArgs *e) {
    (void)rm_forget_channel(owner_of((rdpContext *)ctx), e->name);
}

// MARK: - Connection callbacks

static BOOL rm_pre_connect(freerdp *instance) {
    rdpSettings *settings = instance->context->settings;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_UNSPECIFIED))
        return FALSE;
    if (PubSub_SubscribeChannelConnected(instance->context->pubSub, rm_on_channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, rm_on_channel_disconnected) < 0 ||
        PubSub_SubscribeChannelTerminated(instance->context->pubSub, rm_on_channel_terminated) < 0)
        return FALSE;
    return TRUE;
}

static BOOL rm_post_connect(freerdp *instance) {
    rm_session *owner = owner_of(instance->context);
    // Defense in depth: never continue on Standard RDP Security unless it was chosen, whatever
    // the negotiation ended with.
    if (owner && owner->requested_security != RM_SECURITY_RDP &&
        freerdp_settings_get_uint32(instance->context->settings, FreeRDP_SelectedProtocol) == 0) {
        freerdp_set_last_error_log(instance->context, FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED);
        return FALSE;
    }
    // gdi_init allocates the server-chosen desktop size.
    if (!rm_desktop_size_allowed(freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopWidth),
                                 freerdp_settings_get_uint32(instance->context->settings, FreeRDP_DesktopHeight))) {
        rm_fail(owner, RM_FAILURE_DESKTOP_TOO_LARGE);
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;
    rdpContext *context = instance->context;
    context->update->BeginPaint = rm_begin_paint;
    context->update->EndPaint = rm_end_paint;
    context->update->DesktopResize = rm_desktop_resize;

    rdpPointer pointer = { 0 };
    pointer.size = sizeof(rm_pointer);
    pointer.New = rm_pointer_new;
    pointer.Free = rm_pointer_free;
    pointer.Set = rm_pointer_set;
    pointer.SetNull = rm_pointer_set_null;
    pointer.SetDefault = rm_pointer_set_default;
    pointer.SetPosition = rm_pointer_set_position;
    graphics_register_pointer(context->graphics, &pointer);

    rm_session *session = owner_of(context);
    pthread_mutex_lock(&session->lock);
    session->connected = true;
    pthread_mutex_unlock(&session->lock);
    if (session->callbacks.on_connected)
        session->callbacks.on_connected(session->callbacks.context, context->gdi->width, context->gdi->height,
                                        freerdp_settings_get_uint32(context->settings, FreeRDP_SelectedProtocol));
    return TRUE;
}

static void rm_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context)
        return;
    rm_session *session = owner_of(instance->context);
    if (session) {
        pthread_mutex_lock(&session->lock);
        session->connected = false;
        session->disp = NULL;
        session->cliprdr = NULL;
        pthread_mutex_unlock(&session->lock);
    }
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, rm_on_channel_connected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, rm_on_channel_disconnected);
    PubSub_UnsubscribeChannelTerminated(instance->context->pubSub, rm_on_channel_terminated);
    gdi_free(instance);
}

static DWORD rm_verify(freerdp *instance, const char *host, UINT16 port, const char *subject,
                       const char *issuer, const char *pem, bool changed) {
    rm_session *session = owner_of(instance->context);
    if (!session || !session->callbacks.on_certificate)
        return RM_CERT_REJECT;
    return (DWORD)session->callbacks.on_certificate(session->callbacks.context, host, port, subject, issuer, pem,
                                                    changed);
}

static DWORD rm_verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                   const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    WINPR_UNUSED(common_name);
    if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) == 0)
        return RM_CERT_REJECT; // RDP Manager decides only from the full certificate.
    return rm_verify(instance, host, port, subject, issuer, fingerprint, false);
}

static DWORD rm_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                           const char *common_name, const char *subject, const char *issuer,
                                           const char *fingerprint, const char *old_subject,
                                           const char *old_issuer, const char *old_fingerprint, DWORD flags) {
    WINPR_UNUSED(common_name);
    WINPR_UNUSED(old_subject);
    WINPR_UNUSED(old_issuer);
    WINPR_UNUSED(old_fingerprint);
    if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) == 0)
        return RM_CERT_REJECT;
    return rm_verify(instance, host, port, subject, issuer, fingerprint, true);
}

static BOOL rm_authenticate(freerdp *instance, char **username, char **password, char **domain,
                            rdp_auth_reason reason) {
    WINPR_UNUSED(instance);
    WINPR_UNUSED(username);
    WINPR_UNUSED(password);
    WINPR_UNUSED(domain);
    WINPR_UNUSED(reason);
    // Credentials are set before connecting; the app asks for missing ones itself. Returning
    // FALSE ends the attempt with an authentication error the app turns into a sign-in prompt.
    return FALSE;
}

static BOOL rm_client_new(freerdp *instance, rdpContext *context) {
    WINPR_UNUSED(context);
    instance->PreConnect = rm_pre_connect;
    instance->PostConnect = rm_post_connect;
    instance->PostDisconnect = rm_post_disconnect;
    instance->VerifyCertificateEx = rm_verify_certificate;
    instance->VerifyChangedCertificateEx = rm_verify_changed_certificate;
    instance->AuthenticateEx = rm_authenticate;
    return TRUE;
}

static int rm_client_entry(RDP_CLIENT_ENTRY_POINTS *entry) {
    memset(entry, 0, sizeof(*entry));
    entry->Version = RDP_CLIENT_INTERFACE_VERSION;
    entry->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entry->ContextSize = sizeof(rm_context);
    entry->ClientNew = rm_client_new;
    return 0;
}

// MARK: - Settings

static bool set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
    return !value || !*value || freerdp_settings_set_string(settings, key, value);
}

static bool apply_config(rdpSettings *settings, const rm_config *config) {
    bool ok = freerdp_settings_set_string(settings, FreeRDP_ServerHostname, config->host) &&
              freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config->port) &&
              set_string(settings, FreeRDP_Username, config->username) &&
              set_string(settings, FreeRDP_Domain, config->domain) &&
              set_string(settings, FreeRDP_Password, config->password) &&
              set_string(settings, FreeRDP_ClientHostname, config->client_name) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, config->width) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, config->height) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, config->desktop_scale) &&
              freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, config->device_scale) &&
              freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, config->timeout_ms);
    if (config->keyboard_layout)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, config->keyboard_layout);

    // Security layer: every protocol the user allowed, negotiated strongest first. Standard RDP
    // Security (no server authentication, RC4) only when explicitly chosen: offering it in
    // automatic mode would let anyone in the middle downgrade the connection to it.
    const bool nla = config->security == RM_SECURITY_AUTO || config->security == RM_SECURITY_NLA;
    const bool tls = config->security == RM_SECURITY_AUTO || config->security == RM_SECURITY_TLS;
    const bool rdp = config->security == RM_SECURITY_RDP;
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, nla) &&
         freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, tls) &&
         freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, rdp) &&
         freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, false) &&
         freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_UseRdpSecurityLayer, config->security == RM_SECURITY_RDP);

    switch (config->auth_package) {
    case RM_AUTH_KERBEROS:
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_AuthenticationPackageList, "!ntlm");
        break;
    case RM_AUTH_NTLM:
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_AuthenticationPackageList, "!kerberos");
        break;
    case RM_AUTH_NEGOTIATE:
        break;
    }
    ok = ok && set_string(settings, FreeRDP_KerberosRealm, config->kerberos_realm) &&
         set_string(settings, FreeRDP_KerberosKdcUrl, config->kerberos_kdc_url);

    // Certificates are decided by the app (macOS trust + its own trust store), never accepted
    // silently.
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, false) &&
         freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, false);

    // Graphics: GFX pipeline with RemoteFX/progressive (no H.264 in this build).
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_GfxH264, false) &&
         freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, false) &&
         freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, true) &&
         freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, false); // the app reconnects

    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, config->clipboard) &&
         freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, config->audio_playback) &&
         freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, config->microphone);

    const bool devices = config->printers || config->smartcards || (config->drive_name && config->drive_path);
    ok = ok && freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, devices);
    if (config->printers) {
        const char *args[] = { "printer" };
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, true) &&
             freerdp_client_add_device_channel(settings, 1, args);
    }
    if (config->smartcards) {
        const char *args[] = { "smartcard" };
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, true) &&
             freerdp_client_add_device_channel(settings, 1, args);
    }
    if (config->drive_name && config->drive_path && *config->drive_name && *config->drive_path) {
        const char *args[] = { "drive", config->drive_name, config->drive_path };
        ok = ok && freerdp_client_add_device_channel(settings, 3, args);
    }
    if (config->usb_devices && *config->usb_devices) {
        char ids[512];
        snprintf(ids, sizeof(ids), "id:%s", config->usb_devices);
        const char *args[] = { "urbdrc", ids };
        ok = ok && freerdp_client_add_dynamic_channel(settings, 2, args);
    }
    return ok;
}

// MARK: - Public API

static void rm_global_init(void) {
    // RDP Manager reports errors itself; FreeRDP's console warnings (such as its own empty
    // known-hosts store looking like a changed certificate) only mislead. WLOG_LEVEL=… in the
    // environment still turns them on for debugging.
    if (!getenv("WLOG_LEVEL"))
        (void)WLog_SetLogLevel(WLog_GetRoot(), WLOG_FATAL);
    // Keeps FreeRDP's own configuration (and its known-hosts store) apart from other FreeRDP
    // apps'. RDP Manager answers every certificate "accept once", so nothing is stored there.
    (void)freerdp_setApplicationDetails("RDPManager", "RDPManager", -1);
}

rm_session *rm_session_new(const rm_config *config, const rm_callbacks *callbacks) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, rm_global_init);

    rm_session *session = calloc(1, sizeof(rm_session));
    if (!session)
        return NULL;
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&session->lock, &attributes);
    pthread_mutexattr_destroy(&attributes);
    session->callbacks = *callbacks;
    session->requested_security = config->security;
    session->clipboard_shared = config->clipboard;

    RDP_CLIENT_ENTRY_POINTS entry;
    rm_client_entry(&entry);
    session->context = freerdp_client_context_new(&entry);
    if (!session->context) {
        rm_session_free(session);
        return NULL;
    }
    ((rm_context *)session->context)->owner = session;
    if (!apply_config(session->context->settings, config)) {
        rm_session_free(session);
        return NULL;
    }
    return session;
}

void rm_session_run(rm_session *session) {
    rdpContext *context = session->context;
    freerdp *instance = context->instance;
    uint32_t last_error = 0;
    uint32_t error_info = 0;

    if (freerdp_client_start(context) != 0) {
        last_error = freerdp_get_last_error(context);
        goto done;
    }
    if (!freerdp_connect(instance)) {
        last_error = freerdp_get_last_error(context);
        error_info = freerdp_error_info(instance);
        freerdp_client_stop(context);
        goto done;
    }

    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
    while (!freerdp_shall_disconnect_context(context)) {
        const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
        if (count == 0)
            break;
        if (WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED)
            break;
        if (!freerdp_check_event_handles(context))
            break;
    }
    last_error = freerdp_get_last_error(context);
    error_info = freerdp_error_info(instance);
    freerdp_disconnect(instance);
    freerdp_client_stop(context);

done:
    if (session->callbacks.on_ended) {
        pthread_mutex_lock(&session->lock);
        const rm_failure failure = session->failure;
        pthread_mutex_unlock(&session->lock);
        session->callbacks.on_ended(session->callbacks.context, last_error, error_info, failure);
    }
}

void rm_session_cancel(rm_session *session) {
    if (session && session->context)
        freerdp_abort_connect_context(session->context);
}

void rm_session_free(rm_session *session) {
    if (!session)
        return;
    if (session->context)
        freerdp_client_context_free(session->context);
    free(session->local_clipboard);
    pthread_mutex_destroy(&session->lock);
    free(session);
}

static rdpInput *connected_input(rm_session *session) {
    pthread_mutex_lock(&session->lock);
    rdpInput *input = session->connected ? session->context->input : NULL;
    pthread_mutex_unlock(&session->lock);
    return input;
}

void rm_session_send_mac_key(rm_session *session, uint16_t mac_key_code, bool down) {
    rdpInput *input = connected_input(session);
    if (!input)
        return;
    const DWORD vk = GetVirtualKeyCodeFromKeycode(mac_key_code, WINPR_KEYCODE_TYPE_APPLE);
    const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
    if (scancode == 0)
        return;
    const UINT16 flags = (down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE) | ((scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0);
    (void)freerdp_input_send_keyboard_event(input, flags, (UINT8)(scancode & 0xFF));
}

void rm_session_send_scancode(rm_session *session, uint16_t scancode, bool extended, bool down) {
    rdpInput *input = connected_input(session);
    if (!input)
        return;
    const UINT16 flags = (down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE) | (extended ? KBD_FLAGS_EXTENDED : 0);
    (void)freerdp_input_send_keyboard_event(input, flags, (UINT8)(scancode & 0xFF));
}

void rm_session_send_unicode(rm_session *session, uint16_t code_unit, bool down) {
    rdpInput *input = connected_input(session);
    if (input)
        (void)freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, code_unit);
}

void rm_session_send_pointer(rm_session *session, uint16_t flags, uint16_t x, uint16_t y) {
    rdpInput *input = connected_input(session);
    if (input)
        (void)freerdp_input_send_mouse_event(input, flags, x, y);
}

bool rm_session_resize(rm_session *session, uint32_t width, uint32_t height, uint32_t desktop_scale,
                       uint32_t device_scale) {
    if (!rm_desktop_size_allowed(width, height))
        return false;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width & ~1u; // Display Control requires an even width.
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = desktop_scale;
    layout.DeviceScaleFactor = device_scale;
    // The lock stays held through the call so the channel cannot be freed under it.
    pthread_mutex_lock(&session->lock);
    DispClientContext *disp = session->connected ? session->disp : NULL;
    const bool sent = disp && disp->SendMonitorLayout && disp->SendMonitorLayout(disp, 1, &layout) == CHANNEL_RC_OK;
    pthread_mutex_unlock(&session->lock);
    return sent;
}

void rm_session_set_local_clipboard_text(rm_session *session, const char *utf8) {
    pthread_mutex_lock(&session->lock);
    if (session->clipboard_shared) {
        free(session->local_clipboard);
        session->local_clipboard = utf8 ? strdup(utf8) : NULL;
        CliprdrClientContext *cliprdr = session->connected ? session->cliprdr : NULL;
        if (cliprdr)
            (void)rm_cliprdr_send_format_list(cliprdr, session->local_clipboard != NULL);
    }
    pthread_mutex_unlock(&session->lock);
}

void rm_session_set_clipboard_shared(rm_session *session, bool shared) {
    pthread_mutex_lock(&session->lock);
    session->clipboard_shared = shared;
    if (!shared) {
        // Forget the Mac text and withdraw the offer, so the server can't fetch it any more.
        free(session->local_clipboard);
        session->local_clipboard = NULL;
        CliprdrClientContext *cliprdr = session->connected ? session->cliprdr : NULL;
        if (cliprdr)
            (void)rm_cliprdr_send_format_list(cliprdr, false);
    }
    pthread_mutex_unlock(&session->lock);
}

bool rm_session_offers_clipboard_text(rm_session *session) {
    pthread_mutex_lock(&session->lock);
    const bool offers = session->clipboard_shared && session->local_clipboard != NULL;
    pthread_mutex_unlock(&session->lock);
    return offers;
}

bool rm_desktop_size_is_allowed(uint32_t width, uint32_t height) {
    return rm_desktop_size_allowed(width, height);
}

const char *rm_error_name(uint32_t last_error) {
    return freerdp_get_last_error_name(last_error);
}

const char *rm_error_info_string(uint32_t error_info) {
    return freerdp_get_error_info_string(error_info);
}
