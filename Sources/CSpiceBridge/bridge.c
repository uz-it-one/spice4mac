#include "CSpiceBridge.h"
#include <spice-client.h>
#include <spice/vd_agent.h>
#include <spice/enums.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#define MAX_PIXELS (8192u * 8192u)
#define MAX_CLIPBOARD (1024u * 1024u)
struct SFSession {
 SFConfig config;
 SFCallback callback;
 void *context;
 SpiceSession *session;
 SpiceMainChannel *main;
 SpiceInputsChannel *inputs;
 SpiceDisplayChannel *display;
 int width, height, stride, format, ready;
 uint8_t *canvas;
 gboolean keys[512];
 GBytes *clipboard;
 guint frame_source;
 gboolean diagnostics;
 gint64 stats_start, last_present;
 unsigned invalidations, frames;
};
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void *worker(void *unused) {
 (void)unused;
 pthread_setname_np("Spice4Mac protocol");
 GMainLoop *loop = g_main_loop_new(NULL, FALSE);
 g_main_loop_run(loop);
 return NULL;
}
static void start_worker(void) { pthread_t thread; if (pthread_create(&thread, NULL, worker, NULL)) abort(); pthread_detach(thread); }
static void emit(SFSession *s,int event,int a,int b,int c,int d,const void *data,size_t size) {
 if(s->callback) s->callback(s->context,event,a,b,c,d,data,size);
}
static void state(SFSession *s,const char *text) { emit(s,SF_STATE,0,0,0,0,text,strlen(text)); }
static void error(SFSession *s,const char *text) { emit(s,SF_ERROR,0,0,0,0,text,strlen(text)); }
static int is_32bit(int format) { return format==SPICE_SURFACE_FMT_32_xRGB || format==SPICE_SURFACE_FMT_32_ARGB; }
/* Repack the canvas into tightly packed BGRX8, expanding 16-bit 555/565 pixels. */
static uint8_t *packed_copy(const SFSession *s) {
 size_t row=(size_t)s->width*4;
 uint8_t *copy=g_malloc(row*s->height);
 int greenBits=s->format==SPICE_SURFACE_FMT_16_565 ? 6:5, greenMax=(1<<greenBits)-1;
 for(int y=0;y<s->height;y++) {
  const uint8_t *src=s->canvas+(ptrdiff_t)y*s->stride;
  uint8_t *dst=copy+(size_t)y*row;
  if(is_32bit(s->format)) { memcpy(dst,src,row); continue; }
  for(int x=0;x<s->width;x++) {
   uint16_t v; memcpy(&v,src+x*2,2);
   dst[x*4]=(v&31)*255/31;
   dst[x*4+1]=((v>>5)&greenMax)*255/greenMax;
   dst[x*4+2]=((v>>(5+greenBits))&31)*255/31; dst[x*4+3]=255;
  }
 }
 return copy;
}
static gboolean present(gpointer data) {
 SFSession *s=data; s->frame_source=0;
 if (!s->canvas || s->width<=0 || s->height<=0) return G_SOURCE_REMOVE;
 s->frames++;s->last_present=g_get_monotonic_time();
 /* The callback copies borrowed bytes synchronously. Avoid an intermediate full
    frame allocation and per-pixel alpha loop for the common packed 32-bit canvas. */
 if (is_32bit(s->format) && s->stride==s->width*4) {
  emit(s,SF_FRAME,s->width,s->height,s->stride,0,s->canvas,(size_t)s->stride*s->height);
 } else {
  uint8_t *copy=packed_copy(s);
  emit(s,SF_FRAME,s->width,s->height,s->width*4,0,copy,(size_t)s->width*s->height*4); g_free(copy);
 }
 if(!s->ready) {s->ready=1;state(s,"Ready");}
 return G_SOURCE_REMOVE;
}
static void invalidate(SpiceChannel *ch,int x,int y,int w,int h,gpointer data) {
 (void)ch;(void)x;(void)y;(void)w;(void)h;
 SFSession *s=data;
 if(s->diagnostics){
  s->invalidations++;gint64 now=g_get_monotonic_time();double elapsed=(now-s->stats_start)/1000000.0;
  if(elapsed>=1){fprintf(stderr,"protocol invalidations_per_sec=%.1f published_fps=%.1f size=%dx%d\n",s->invalidations/elapsed,s->frames/elapsed,s->width,s->height);s->stats_start=now;s->invalidations=0;s->frames=0;}
 }
 if(!s->frame_source) {
  gint64 elapsed=(g_get_monotonic_time()-s->last_present)/1000;
  s->frame_source=g_timeout_add((guint)MAX(1,16-elapsed),present,s);
 }
}
static void primary(SpiceChannel *ch,int format,int w,int h,int stride,int shmid,void *pixels,gpointer data) {
 (void)ch;(void)shmid; SFSession *s=data;s->canvas=NULL;
 if(w<=0 || h<=0 || w>8192 || h>8192 || (uint64_t)w*h>MAX_PIXELS ||
    (!is_32bit(format) && format!=SPICE_SURFACE_FMT_16_555 && format!=SPICE_SURFACE_FMT_16_565) ||
    llabs((long long)stride)<(long long)w*(is_32bit(format)?4:2)) {
  error(s,"Unsupported or oversized display surface"); return;
 }
 s->width=w;s->height=h;s->stride=stride;s->format=format;s->canvas=pixels;
 /* Wait for display-invalidate: a newly allocated surface is not a rendered frame. */
}
static void primary_destroy(SpiceChannel *ch,gpointer data) {
 (void)ch;SFSession*s=data;s->canvas=NULL;s->ready=0;
 if(s->frame_source){g_source_remove(s->frame_source);s->frame_source=0;}
 emit(s,SF_CLEAR,0,0,0,0,NULL,0);
}
static void cursor_set(SpiceChannel *ch,int w,int h,int x,int y,void*pixels,gpointer data) {
 (void)ch; if(w>0&&h>0&&w<=512&&h<=512&&pixels) emit(data,SF_CURSOR,w,h,x,y,pixels,(size_t)w*h*4);
}
static void cursor_hide(SpiceChannel *ch,gpointer data){(void)ch;emit(data,SF_CURSOR,0,0,0,0,NULL,0);}
static void agent_update(SpiceChannel *ch,gpointer data) {
 gboolean connected=FALSE;g_object_get(ch,"agent-connected",&connected,NULL);
 emit(data,SF_AGENT,connected,0,0,0,NULL,0);
}
static void mouse_update(SpiceChannel*ch,gpointer data){int mode=0;g_object_get(ch,"mouse-mode",&mode,NULL);emit(data,SF_MOUSE,mode==SPICE_MOUSE_MODE_SERVER,0,0,0,NULL,0);}
static gboolean clipboard_grab(SpiceMainChannel*ch,guint selection,gpointer types,guint count,gpointer data){
 SFSession*s=data;if(!s->config.clipboard||selection!=VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD||count>256)return FALSE;
 for(guint i=0;i<count;i++)if(((guint32*)types)[i]==VD_AGENT_CLIPBOARD_UTF8_TEXT){spice_main_channel_clipboard_selection_request(ch,selection,VD_AGENT_CLIPBOARD_UTF8_TEXT);return TRUE;}return FALSE;
}
static void clipboard_data(SpiceMainChannel*ch,guint selection,guint type,gpointer bytes,guint size,gpointer data){
 (void)ch;SFSession*s=data;if(s->config.clipboard&&selection==VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD&&type==VD_AGENT_CLIPBOARD_UTF8_TEXT&&size<=MAX_CLIPBOARD&&g_utf8_validate(bytes,size,NULL))emit(s,SF_CLIPBOARD,0,0,0,0,bytes,size);
}
static gboolean clipboard_request(SpiceMainChannel*ch,guint selection,guint type,gpointer data){
 SFSession*s=data;if(!s->config.clipboard||!s->clipboard||selection!=VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD||type!=VD_AGENT_CLIPBOARD_UTF8_TEXT)return FALSE;
 gsize size;const void*bytes=g_bytes_get_data(s->clipboard,&size);spice_main_channel_clipboard_selection_notify(ch,selection,type,bytes,size);return TRUE;
}
static void audio_start(SpiceChannel*ch,int format,int channels,int rate,gpointer data){(void)ch;if(format==SPICE_AUDIO_FMT_S16&&channels>=1&&channels<=2&&rate>=8000&&rate<=192000)emit(data,SF_AUDIO_START,rate,channels,0,0,NULL,0);}
static void audio_data(SpiceChannel*ch,void*bytes,int size,gpointer data){(void)ch;if(size>0&&size<=1024*1024)emit(data,SF_AUDIO_DATA,0,0,0,0,bytes,size);}
static void audio_stop(SpiceChannel*ch,gpointer data){(void)ch;emit(data,SF_AUDIO_STOP,0,0,0,0,NULL,0);}
static void channel_event(SpiceChannel*ch,SpiceChannelEvent event,gpointer data){
 SFSession*s=data;
 if(event==SPICE_CHANNEL_OPENED){if(SPICE_IS_MAIN_CHANNEL(ch))state(s,"Negotiating");return;}
 if(event==SPICE_CHANNEL_SWITCHING){state(s,"Migrating");return;}
 if(event==SPICE_CHANNEL_CLOSED){if(SPICE_IS_MAIN_CHANNEL(ch)){state(s,"Disconnected");s->ready=0;}return;}
 switch(event){
 case SPICE_CHANNEL_ERROR_AUTH:error(s,"Authentication failed (ticket may have expired)");break;
 case SPICE_CHANNEL_ERROR_TLS:error(s,"TLS verification or handshake failed");break;
 case SPICE_CHANNEL_ERROR_CONNECT:error(s,"Unable to connect to server or proxy");break;
 case SPICE_CHANNEL_ERROR_IO:error(s,"Network connection interrupted");break;
 case SPICE_CHANNEL_ERROR_LINK:error(s,"SPICE channel negotiation failed");break;
 default:break;
 }
}
static void channel_new(SpiceSession*session,SpiceChannel*ch,gpointer data){
 (void)session;SFSession*s=data;int id=0;g_object_get(ch,"channel-id",&id,NULL);
 g_signal_connect(ch,"channel-event",G_CALLBACK(channel_event),s);
 if(SPICE_IS_MAIN_CHANNEL(ch)) {
  s->main=SPICE_MAIN_CHANNEL(ch);
  g_object_set(ch,"max-clipboard",MAX_CLIPBOARD,NULL);
  g_signal_connect(ch,"main-agent-update",G_CALLBACK(agent_update),s);
  g_signal_connect(ch,"main-mouse-update",G_CALLBACK(mouse_update),s);
  g_signal_connect(ch,"main-clipboard-selection-grab",G_CALLBACK(clipboard_grab),s);
  g_signal_connect(ch,"main-clipboard-selection",G_CALLBACK(clipboard_data),s);
  g_signal_connect(ch,"main-clipboard-selection-request",G_CALLBACK(clipboard_request),s);
 } else if(SPICE_IS_DISPLAY_CHANNEL(ch)&&id==0){
  s->display=SPICE_DISPLAY_CHANNEL(ch);
  g_signal_connect(ch,"display-primary-create",G_CALLBACK(primary),s);
  g_signal_connect(ch,"display-primary-destroy",G_CALLBACK(primary_destroy),s);
  g_signal_connect(ch,"display-invalidate",G_CALLBACK(invalidate),s);
  spice_channel_connect(ch);
 } else if(SPICE_IS_INPUTS_CHANNEL(ch)&&id==0){s->inputs=SPICE_INPUTS_CHANNEL(ch);spice_channel_connect(ch);}
 else if(SPICE_IS_CURSOR_CHANNEL(ch)&&id==0){
  g_signal_connect(ch,"cursor-set",G_CALLBACK(cursor_set),s);g_signal_connect(ch,"cursor-hide",G_CALLBACK(cursor_hide),s);g_signal_connect(ch,"cursor-reset",G_CALLBACK(cursor_hide),s);spice_channel_connect(ch);
 } else if(SPICE_IS_PLAYBACK_CHANNEL(ch)&&s->config.audio){
  g_signal_connect(ch,"playback-start",G_CALLBACK(audio_start),s);g_signal_connect(ch,"playback-data",G_CALLBACK(audio_data),s);g_signal_connect(ch,"playback-stop",G_CALLBACK(audio_stop),s);spice_channel_connect(ch);
 }
 /* Record, USB, smartcard and shared-folder channels intentionally never connected. */
}
static void channel_destroy(SpiceSession*session,SpiceChannel*ch,gpointer data){
 (void)session;SFSession*s=data;
 if((void*)ch==s->main)s->main=NULL;
 if((void*)ch==s->inputs){s->inputs=NULL;memset(s->keys,0,sizeof(s->keys));}
 if((void*)ch==s->display){primary_destroy(ch,s);s->display=NULL;}
 g_signal_handlers_disconnect_by_data(ch,s);
}
static gboolean begin(gpointer data){
 SFSession*s=data;s->session=spice_session_new();
 g_object_set(s->session,"host",s->config.host,"password",s->config.password,"enable-usbredir",FALSE,"enable-smartcard",FALSE,"enable-audio",s->config.audio,NULL);
 if(s->config.insecure){g_object_set(s->session,"port",s->config.port,NULL);}else{
  const char*secure[]={"all",NULL};g_object_set(s->session,"tls-port",s->config.tls_port,"secure-channels",secure,NULL);
 }
 if(s->config.ca_file)g_object_set(s->session,"ca-file",s->config.ca_file,NULL);
 if(s->config.ca_pem){GByteArray*ca=g_byte_array_new();g_byte_array_append(ca,(const guint8*)s->config.ca_pem,strlen(s->config.ca_pem));g_object_set(s->session,"ca",ca,"ca-file",NULL,NULL);g_byte_array_unref(ca);}
 if(s->config.subject)g_object_set(s->session,"cert-subject",s->config.subject,NULL);
 if(s->config.proxy)g_object_set(s->session,"proxy",s->config.proxy,NULL);
 g_signal_connect(s->session,"channel-new",G_CALLBACK(channel_new),s);g_signal_connect(s->session,"channel-destroy",G_CALLBACK(channel_destroy),s);
 state(s,"Connecting");if(!spice_session_connect(s->session))error(s,"Unable to start SPICE connection");return G_SOURCE_REMOVE;
}
SFSession*sf_session_create(const SFConfig*config,SFCallback callback,void*context){
 pthread_once(&once,start_worker);SFSession*s=g_new0(SFSession,1);s->config=*config;s->callback=callback;s->context=context;
 s->diagnostics=g_strcmp0(g_getenv("SPICE4MAC_DIAGNOSTICS"),"1")==0;s->stats_start=g_get_monotonic_time();
 #define DUP(f) s->config.f=g_strdup(config->f)
 DUP(host);DUP(port);DUP(tls_port);DUP(password);DUP(ca_file);DUP(ca_pem);DUP(subject);DUP(proxy);
 #undef DUP
 g_idle_add(begin,s);return s;
}
static void release(SFSession*s){if(s->inputs){for(guint i=0;i<512;i++)if(s->keys[i])spice_inputs_channel_key_release(s->inputs,i);for(int b=1;b<=3;b++)spice_inputs_channel_button_release(s->inputs,b,0);}memset(s->keys,0,sizeof(s->keys));}
static gboolean destroy(gpointer data){
 SFSession*s=data;release(s);if(s->frame_source)g_source_remove(s->frame_source);
 if(s->session){GList*channels=spice_session_get_channels(s->session);for(GList*l=channels;l;l=l->next)g_signal_handlers_disconnect_by_data(l->data,s);g_list_free(channels);g_signal_handlers_disconnect_by_data(s->session,s);spice_session_disconnect(s->session);g_object_unref(s->session);}
 if(s->clipboard)g_bytes_unref(s->clipboard);
 #define FREE(f) g_free((void*)s->config.f)
 FREE(host);FREE(port);FREE(tls_port);if(s->config.password)memset((void*)s->config.password,0,strlen(s->config.password));FREE(password);FREE(ca_file);FREE(ca_pem);FREE(subject);FREE(proxy);
 #undef FREE
 emit(s,SF_DESTROYED,0,0,0,0,NULL,0);g_free(s);return G_SOURCE_REMOVE;
}
void sf_session_destroy(SFSession*s){if(s)g_idle_add(destroy,s);}
enum { CMD_KEY=1, CMD_POINTER, CMD_BUTTON, CMD_RELEASE, CMD_RESOLUTION, CMD_CLIPBOARD };
typedef struct{SFSession*s;int kind,a,b,c,d;GBytes*bytes;} Command;
static gboolean command(gpointer data){Command*q=data;SFSession*s=q->s;
 switch(q->kind){
 case CMD_KEY:if(s->inputs&&q->a>=0&&q->a<512){if(q->b)spice_inputs_channel_key_press(s->inputs,q->a);else spice_inputs_channel_key_release(s->inputs,q->a);s->keys[q->a]=q->b;}break;
 case CMD_POINTER:if(s->inputs){if(q->d)spice_inputs_channel_motion(s->inputs,q->a,q->b,q->c);else spice_inputs_channel_position(s->inputs,q->a,q->b,0,q->c);}break;
 case CMD_BUTTON:if(s->inputs){if(q->b)spice_inputs_channel_button_press(s->inputs,q->a,q->c);else spice_inputs_channel_button_release(s->inputs,q->a,q->c);}break;
 case CMD_RELEASE:release(s);break;
 case CMD_RESOLUTION:if(s->main&&q->a>=320&&q->a<=8192&&q->b>=200&&q->b<=8192&&spice_main_channel_agent_test_capability(s->main,VD_AGENT_CAP_MONITORS_CONFIG)){spice_main_channel_update_display(s->main,0,0,0,q->a,q->b,TRUE);spice_main_channel_send_monitor_config(s->main);}break;
 case CMD_CLIPBOARD:if(s->config.clipboard){if(s->clipboard)g_bytes_unref(s->clipboard);s->clipboard=g_bytes_ref(q->bytes);if(s->main){guint32 type=VD_AGENT_CLIPBOARD_UTF8_TEXT;spice_main_channel_clipboard_selection_grab(s->main,VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,&type,1);}}break;
 }if(q->bytes)g_bytes_unref(q->bytes);g_free(q);return G_SOURCE_REMOVE;
}
static void enqueue(SFSession*s,int kind,int a,int b,int c,int d,GBytes*bytes){if(!s)return;Command*q=g_new0(Command,1);*q=(Command){s,kind,a,b,c,d,bytes};g_idle_add(command,q);}
void sf_key(SFSession*s,uint32_t code,int pressed){enqueue(s,CMD_KEY,code,pressed,0,0,NULL);}
void sf_pointer(SFSession*s,int x,int y,int buttons,int relative){enqueue(s,CMD_POINTER,x,y,buttons,relative,NULL);}
void sf_button(SFSession*s,int button,int pressed,int buttons){enqueue(s,CMD_BUTTON,button,pressed,buttons,0,NULL);}
void sf_release_keys(SFSession*s){enqueue(s,CMD_RELEASE,0,0,0,0,NULL);}
void sf_resolution(SFSession*s,int w,int h){enqueue(s,CMD_RESOLUTION,w,h,0,0,NULL);}
void sf_clipboard(SFSession*s,const uint8_t*text,size_t size){if(s&&size<=MAX_CLIPBOARD)enqueue(s,CMD_CLIPBOARD,0,0,0,0,g_bytes_new(text,size));}
const char*sf_backend_version(void){return spice_util_get_version_string();}
