#include <assert.h>
#include <math.h>
#include "../native/helios-viewer/frame-policy.h"
int main(void){
 int x,y;assert(frame_relative_motion(640,400,1281,801,1,&x,&y)&&x==0&&y==0);
 assert(frame_relative_motion(643,398,1281,801,1,&x,&y)&&x==3&&y==-2);
 assert(frame_relative_motion(640.5,400.5,1281,801,2,&x,&y)&&x==0&&y==0);
 assert(frame_relative_motion(642,400,1281,801,2,&x,&y)&&x==3&&y==-1);
 assert(!frame_relative_motion(INFINITY,0,1280,800,1,&x,&y));assert(!frame_relative_motion(1,1,0,0,1,&x,&y));assert(!frame_relative_motion(1e20,0,1280,800,1,&x,&y));
 return 0;
}
