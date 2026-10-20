/* CPU conversion comparison only; no GPU, presentation or FPS claim. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../../native/helios-viewer/frame-policy.h"
static double stamp(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static volatile unsigned observe;
int main(void){
 unsigned w=1920,h=1080,stride=w*4+8;size_t n=(size_t)stride*h;
 uint8_t *in=malloc(n),*out=malloc(n);if(!in||!out)return 2;
 for(size_t i=0;i<n;i++)in[i]=(uint8_t)i;
 for(unsigned run=0;run<4;run++){
  double start=stamp();
  for(unsigned j=0;j<80;j++){
   if(run%2==0){memcpy(out,in,n);for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){size_t i=(size_t)y*stride+x*4;uint8_t b=out[i];out[i]=out[i+2];out[i+2]=b;}}
   else frame_bgra_to_rgba(out,in,w,h,stride);
   observe+=out[j*4];
  }
  printf("%s %.3f ms/frame\n",run%2?"B-one-pass":"A-copy-swap",(stamp()-start)*1000/80);
 }
 free(in);free(out);return 0;
}
