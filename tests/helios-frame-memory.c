#include <assert.h>
#include <string.h>
#include "../native/helios-viewer/frame-policy.h"
int main(void){
    assert(frame_linear_fits(2,2,12,0,20));
    assert(!frame_linear_fits(2,2,12,1,20));
    assert(!frame_linear_fits(2,2,7,0,100));
    assert(!frame_linear_fits(UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT64_MAX));
    uint8_t input[24]={1,2,3,4,5,6,7,8,99,99,99,99,9,10,11,12,13,14,15,16};
    uint8_t output[24];memset(output,77,sizeof(output));
    frame_bgra_to_rgba(output,input,2,2,12);
    assert(output[0]==3 && output[2]==1 && output[12]==11 && output[15]==12);
    assert(output[8]==77 && output[11]==77 && output[20]==77);
}
