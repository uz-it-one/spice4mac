/* Local test server using the actual upstream libspice-server, not a mock wire protocol. */
#include <spice.h>
#include <glib.h>
#include <glib-unix.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
struct SpiceTimer { guint source; SpiceTimerFunc func; void*opaque; };
struct SpiceWatch { guint source; int fd; SpiceWatchFunc func;void*opaque; };
static gboolean timer_call(void*p){SpiceTimer*t=p;t->source=0;t->func(t->opaque);return G_SOURCE_REMOVE;}
static SpiceTimer*timer_add(SpiceTimerFunc f,void*p){SpiceTimer*t=g_new0(SpiceTimer,1);t->func=f;t->opaque=p;return t;}
static void timer_cancel(SpiceTimer*t){if(t->source){g_source_remove(t->source);t->source=0;}}
static void timer_start(SpiceTimer*t,uint32_t ms){timer_cancel(t);t->source=g_timeout_add(ms,timer_call,t);}
static void timer_remove(SpiceTimer*t){timer_cancel(t);g_free(t);}
static gboolean watch_call(gint fd,GIOCondition condition,gpointer p){SpiceWatch*w=p;int event=0;if(condition&(G_IO_IN|G_IO_HUP|G_IO_ERR))event|=SPICE_WATCH_EVENT_READ;if(condition&G_IO_OUT)event|=SPICE_WATCH_EVENT_WRITE;w->func(fd,event,w->opaque);return G_SOURCE_CONTINUE;}
static void watch_update(SpiceWatch*w,int mask){if(w->source)g_source_remove(w->source);w->source=0;if(mask)w->source=g_unix_fd_add(w->fd,((mask&SPICE_WATCH_EVENT_READ)?G_IO_IN:0)|((mask&SPICE_WATCH_EVENT_WRITE)?G_IO_OUT:0),watch_call,w);}
static SpiceWatch*watch_add(int fd,int mask,SpiceWatchFunc f,void*p){SpiceWatch*w=g_new0(SpiceWatch,1);w->fd=fd;w->func=f;w->opaque=p;watch_update(w,mask);return w;}
static void watch_remove(SpiceWatch*w){watch_update(w,0);g_free(w);}
static void channel_event(int event,SpiceChannelEventInfo*info){printf("channel %d type %d tls %d\n",event,info->type,!!(info->flags&SPICE_CHANNEL_EVENT_FLAG_TLS));fflush(stdout);}
static SpiceCoreInterface core={.base={.type=SPICE_INTERFACE_CORE,.description="fixture",.major_version=SPICE_INTERFACE_CORE_MAJOR,.minor_version=SPICE_INTERFACE_CORE_MINOR},.timer_add=timer_add,.timer_start=timer_start,.timer_cancel=timer_cancel,.timer_remove=timer_remove,.watch_add=watch_add,.watch_update_mask=watch_update,.watch_remove=watch_remove,.channel_event=channel_event};
static SpiceServer*server;
static uint32_t *pixels;
static int width=640,height=480;
static void attach(QXLInstance*q){QXLDevMemSlot slot={.slot_group_id=0,.slot_id=0,.virt_start=0,.virt_end=UINTPTR_MAX,.qxl_ram_size=UINT32_MAX};spice_qxl_add_memslot(q,&slot);QXLDevSurfaceCreate surface={.width=width,.height=height,.stride=-width*4,.format=SPICE_SURFACE_FMT_32_xRGB,.mouse_mode=1,.flags=QXL_SURF_FLAG_KEEP_DATA,.mem=(uintptr_t)pixels,.group_id=0};spice_qxl_create_primary_surface(q,0,&surface);spice_server_vm_start(server);}
static void compression(QXLInstance*q,int level){(void)q;(void)level;}
static void init_info(QXLInstance*q,QXLDevInitInfo*i){(void)q;memset(i,0,sizeof(*i));i->num_memslots=1;i->num_memslots_groups=1;i->memslot_id_bits=1;i->memslot_gen_bits=1;i->n_surfaces=1;}
static GAsyncQueue *commands;
static int get_command(QXLInstance*q,QXLCommandExt*c){
 (void)q; QXLDrawable *draw=commands?g_async_queue_try_pop(commands):NULL;
 if(!draw)return 0; memset(c,0,sizeof(*c));c->cmd.type=QXL_CMD_DRAW;c->cmd.data=(uintptr_t)draw;return 1;
}
static int get_cursor_command(QXLInstance*q,QXLCommandExt*c){(void)q;(void)c;return 0;}
static int notification(QXLInstance*q){(void)q;return 1;}
static void release(QXLInstance*q,QXLReleaseInfoExt i){(void)q;g_free((void*)(uintptr_t)i.info->id);}
static void update(QXLInstance*q,uint32_t id){(void)q;(void)id;}
static QXLInterface display={.base={SPICE_INTERFACE_QXL,"Fixture display",SPICE_INTERFACE_QXL_MAJOR,SPICE_INTERFACE_QXL_MINOR},.attached_worker=attach,.set_compression_level=compression,.get_init_info=init_info,.get_command=get_command,.req_cmd_notification=notification,.release_resource=release,.get_cursor_command=get_cursor_command,.req_cursor_notification=notification,.notify_update=update,.flush_resources=notification};
static QXLInstance qxl={.base={.sif=&display.base},.id=0};
static void key(SpiceKbdInstance*k,uint8_t code){(void)k;printf("key %u\n",code);fflush(stdout);}
static uint8_t leds(SpiceKbdInstance*k){(void)k;return 0;}
static SpiceKbdInterface keyboard={.base={SPICE_INTERFACE_KEYBOARD,"Fixture keyboard",1,1},.push_scan_freg=key,.get_leds=leds};
static SpiceKbdInstance kbd={.base={.sif=&keyboard.base}};
static void logical(SpiceTabletInstance*t,int w,int h){(void)t;(void)w;(void)h;}
static void position(SpiceTabletInstance*t,int x,int y,uint32_t b){(void)t;printf("pointer %d %d %u\n",x,y,b);fflush(stdout);}
static void buttons(SpiceTabletInstance*t,uint32_t b){(void)t;printf("buttons %u\n",b);fflush(stdout);}
static void wheel(SpiceTabletInstance*t,int dz,uint32_t b){(void)t;printf("wheel %d buttons %u\n",dz,b);fflush(stdout);}
static SpiceTabletInterface tablet_if={.base={SPICE_INTERFACE_TABLET,"Fixture tablet",1,1},.set_logical_size=logical,.position=position,.wheel=wheel,.buttons=buttons};
static SpiceTabletInstance tablet={.base={.sif=&tablet_if.base}};
static gboolean animate(gpointer unused){
 (void)unused;static unsigned sequence=0;
 if(g_async_queue_length(commands)>4)return G_SOURCE_CONTINUE;
 QXLDrawable*d=g_new0(QXLDrawable,1);d->release_info.id=(uintptr_t)d;
 d->type=QXL_DRAW_FILL;d->effect=QXL_EFFECT_OPAQUE;d->bbox.right=width;d->bbox.bottom=height;
 d->surfaces_dest[0]=d->surfaces_dest[1]=d->surfaces_dest[2]=-1;
 d->u.fill.brush.type=SPICE_BRUSH_TYPE_SOLID;d->u.fill.brush.u.color=0xff000000u|((++sequence*7919)&0xffffff);
 if(g_getenv("SPICE_FIXTURE_ROWS")){d->bbox.top=(sequence*16)%height;d->bbox.bottom=MIN(height,d->bbox.top+16);}
 d->u.fill.rop_descriptor=SPICE_ROPD_OP_PUT;
 g_async_queue_push(commands,d);spice_qxl_wakeup(&qxl);return G_SOURCE_CONTINUE;
}
int main(int argc,char**argv){
 int port=argc>1?atoi(argv[1]):15900; if(port<1024||port>65535)return 64;
 if(g_getenv("SPICE_FIXTURE_WIDTH"))width=atoi(g_getenv("SPICE_FIXTURE_WIDTH"));
 if(g_getenv("SPICE_FIXTURE_HEIGHT"))height=atoi(g_getenv("SPICE_FIXTURE_HEIGHT"));
 if(width<2||height<2||width>8192||height>8192)return 64;
 pixels=g_new(uint32_t,(size_t)width*height);
 for(int y=0;y<height;y++)for(int x=0;x<width;x++)pixels[y*width+x]=0xff000000u|((x*255/(width-1))<<16)|((y*255/(height-1))<<8)|0x60;
 server=spice_server_new();spice_server_set_addr(server,"127.0.0.1",SPICE_ADDR_FLAG_IPV4_ONLY);
 if(argc==5){if(spice_server_set_tls(server,port,argv[2],argv[3],argv[4],NULL,NULL,NULL))return 1;}else spice_server_set_port(server,port);
 const char*ticket=g_getenv("SPICE_FIXTURE_TICKET");if(ticket)spice_server_set_ticket(server,ticket,3600,0,0);else spice_server_set_noauth(server);
 spice_server_set_image_compression(server,SPICE_IMAGE_COMPRESSION_OFF);
 if(spice_server_init(server,&core))return 1;
 spice_server_add_interface(server,&kbd.base);spice_server_add_interface(server,&tablet.base);spice_server_add_interface(server,&qxl.base);
 if(g_getenv("SPICE_FIXTURE_ANIMATE")){commands=g_async_queue_new();g_timeout_add(16,animate,NULL);}
 printf("ready %d\n",port);fflush(stdout);g_main_loop_run(g_main_loop_new(NULL,FALSE));return 0;
}
