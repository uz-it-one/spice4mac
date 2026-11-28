/* Unit checks for bridge.c internals that the loopback fixture cannot reach:
   16-bit surface repacking, padded strides and dirty-rectangle accumulation.
   Built by Build/test.sh by including bridge.c directly. */
#include "../../Sources/CSpiceBridge/bridge.c"
#include <assert.h>

static int failures=0;
#define CHECK(cond,...) do{ if(!(cond)){ fprintf(stderr,"FAIL %s:%d: ",__FILE__,__LINE__); fprintf(stderr,__VA_ARGS__); fputc('\n',stderr); failures++; } }while(0)

static uint8_t expand(unsigned value,unsigned bits){ return (uint8_t)(value*255/((1u<<bits)-1)); }

static void check_16bit(int format){
 int greenBits=format==SPICE_SURFACE_FMT_16_565?6:5;
 uint8_t *canvas=g_malloc(65536*2);
 for(int v=0;v<65536;v++){canvas[v*2]=v&255;canvas[v*2+1]=v>>8;}
 SFSession s={0};s.width=65536;s.height=1;s.stride=65536*2;s.format=format;s.canvas=canvas;
 uint8_t *out=packed_copy(&s);
 for(unsigned v=0;v<65536;v++){
  uint8_t b=expand(v&31,5),g=expand((v>>5)&((1u<<greenBits)-1),greenBits),r=expand((v>>(5+greenBits))&31,5);
  const uint8_t *px=out+v*4;
  if(px[0]!=b||px[1]!=g||px[2]!=r||px[3]!=255){CHECK(0,"format %d value 0x%04x -> %u,%u,%u,%u",format,v,px[0],px[1],px[2],px[3]);break;}
 }
 g_free(out);g_free(canvas);
}

static void check_padded_32bit(void){
 int w=7,h=3,stride=w*4+12;
 uint8_t *canvas=g_malloc((size_t)stride*h);
 for(int i=0;i<stride*h;i++)canvas[i]=(uint8_t)(i*31+3);
 SFSession s={0};s.width=w;s.height=h;s.stride=stride;s.format=SPICE_SURFACE_FMT_32_xRGB;s.canvas=canvas;
 uint8_t *out=packed_copy(&s);
 for(int y=0;y<h;y++)CHECK(memcmp(out+y*w*4,canvas+y*stride,(size_t)w*4)==0,"row %d not copied tightly",y);
 g_free(out);g_free(canvas);
}

static int seen_dirty[4],seen_frames;
static void capture(void*ctx,int event,int a,int b,int c,int d,const uint8_t*data,size_t size){
 (void)ctx;(void)data;(void)size;
 if(event==SF_DIRTY){seen_dirty[0]=a;seen_dirty[1]=b;seen_dirty[2]=c;seen_dirty[3]=d;}
 if(event==SF_FRAME)seen_frames++;
}

static void check_dirty(void){
 uint32_t pixels[64*32]={0};
 SFSession s={0};s.callback=capture;s.width=64;s.height=32;s.stride=64*4;s.format=SPICE_SURFACE_FMT_32_xRGB;s.canvas=(uint8_t*)pixels;s.ready=1;
 add_dirty(&s,10,4,5,2); add_dirty(&s,2,20,3,3); add_dirty(&s,0,0,0,9); /* empty rect ignored */
 present(&s);
 CHECK(seen_frames==1,"one frame expected, got %d",seen_frames);
 CHECK(seen_dirty[0]==2&&seen_dirty[1]==4&&seen_dirty[2]==13&&seen_dirty[3]==19,"union wrong: %d,%d %dx%d",seen_dirty[0],seen_dirty[1],seen_dirty[2],seen_dirty[3]);
 /* Nothing accumulated (e.g. first frame after surface creation) means the whole surface. */
 present(&s);
 CHECK(seen_dirty[0]==0&&seen_dirty[1]==0&&seen_dirty[2]==64&&seen_dirty[3]==32,"reset/full wrong: %d,%d %dx%d",seen_dirty[0],seen_dirty[1],seen_dirty[2],seen_dirty[3]);
 /* Regions reaching past the surface are clipped. */
 add_dirty(&s,60,30,10,10); present(&s);
 CHECK(seen_dirty[0]==60&&seen_dirty[1]==30&&seen_dirty[2]==4&&seen_dirty[3]==2,"clip wrong: %d,%d %dx%d",seen_dirty[0],seen_dirty[1],seen_dirty[2],seen_dirty[3]);
}

int main(void){
 check_16bit(SPICE_SURFACE_FMT_16_555);
 check_16bit(SPICE_SURFACE_FMT_16_565);
 check_padded_32bit();
 check_dirty();
 if(failures){fprintf(stderr,"%d bridge check(s) failed\n",failures);return 1;}
 puts("PASS: bridge repacking (555/565 exhaustive, padded stride) and dirty rectangles");
 return 0;
}
