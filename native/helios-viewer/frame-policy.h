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
