/* SPDX-License-Identifier: MIT */
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct FramePacer { bool initialized; int64_t last_us; } FramePacer;
static inline bool frame_pacer_consume(FramePacer *p, int64_t now, unsigned fps, bool background)
{
    if (background && fps && p->initialized && now >= p->last_us &&
        now - p->last_us < INT64_C(1000000) / fps) { return false; }
    p->initialized = true;
    p->last_us = now;
    return true;
}
/* Packed 32-bit RGB linear layout only. Never apply to opaque modifiers. */
static inline bool frame_linear_fits(uint32_t width,uint32_t height,uint32_t stride,
                                     uint32_t offset,uint64_t bytes)
{
    if (!width || !height || (uint64_t)stride < (uint64_t)width*4) return false;
    uint64_t end=(uint64_t)offset+(uint64_t)(height-1)*stride+(uint64_t)width*4;
    return end<=bytes;
}
static inline void frame_bgra_to_rgba(uint8_t *out,const uint8_t *in,
                                      uint32_t width,uint32_t height,uint32_t stride)
{
    for(uint32_t y=0;y<height;y++) for(uint32_t x=0;x<width;x++) {
        uint64_t i=(uint64_t)y*stride+(uint64_t)x*4;
        out[i]=in[i+2];out[i+1]=in[i+1];out[i+2]=in[i];out[i+3]=in[i+3];
    }
}
