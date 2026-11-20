#include "CSpiceBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static int result=-1, destroyed=0;
static void event(void*ctx,int type,int a,int b,int c,int d,const uint8_t*data,size_t size){
 (void)ctx;(void)c;(void)d;
 pthread_mutex_lock(&lock);
 if(type==SF_FRAME){if(a==640&&b==480&&size==640*480*4 && data[0]==0x60 && data[2]<10 && data[4*639+2]>200)result=0;else result=3;}
 if(type==SF_ERROR){fprintf(stderr,"%.*s\n",(int)size,data);result=2;}
 if(type==SF_DESTROYED)destroyed=1;
 if(type==SF_STATE)fprintf(stderr,"state %.*s\n",(int)size,data);
 pthread_cond_signal(&cond);pthread_mutex_unlock(&lock);
}
int main(int argc,char**argv){
 SFConfig config={.host="127.0.0.1",.port=argc>1?argv[1]:"15900",.insecure=1};
 if(argc>2){config.insecure=0;config.tls_port=config.port;config.port=NULL;config.ca_file=argv[2];}
 if(argc>3)config.subject=argv[3];
 config.password=getenv("SPICE_FIXTURE_TICKET");
 int cycles=getenv("SPICE_SMOKE_CYCLES")?atoi(getenv("SPICE_SMOKE_CYCLES")):1;
 for(int cycle=0;cycle<cycles;cycle++){result=-1;destroyed=0;
 SFSession*s=sf_session_create(&config,event,NULL);struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=10;
 pthread_mutex_lock(&lock);while(result<0)if(pthread_cond_timedwait(&cond,&lock,&until))break;int status=result;pthread_mutex_unlock(&lock);
 if(status==0){sf_key(s,0x1e,1);sf_key(s,0x1e,0);sf_pointer(s,42,84,0,0);sf_button(s,1,1,1);sf_button(s,1,0,0);}
 usleep(200000);sf_session_destroy(s);pthread_mutex_lock(&lock);while(!destroyed)if(pthread_cond_timedwait(&cond,&lock,&until))break;pthread_mutex_unlock(&lock);
 printf("{\"result\":%d,\"destroyed\":%s}\n",status,destroyed?"true":"false");if(status!=0||!destroyed)return status<0?4:status;
 }return 0;
}
