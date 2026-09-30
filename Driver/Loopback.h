#ifndef MIXOTO_LOOPBACK_H
#define MIXOTO_LOOPBACK_H
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

// Fixed stereo float32 / 48 kHz transport. This explicit 2048-frame delay
// provides four 512-frame cycles of write/read scheduling headroom. It is not
// a measured end-to-end delay. Old/missing frames are silence, never replayed.
enum { MX_CHANNELS = 2, MX_RATE = 48000, MX_PERIOD = 512,
       MX_DELAY_FRAMES = 2048, MX_RING_FRAMES = 16384, MX_MAX_IO_FRAMES = 4096 };

typedef struct {
    _Atomic uint64_t frame;
    _Atomic uint64_t stereo;
} MXFrame;
typedef struct { MXFrame frames[MX_RING_FRAMES]; } MXLoopback;

void MXLoopbackReset(MXLoopback *ring); // Only while all I/O is stopped.
void MXLoopbackWrite(MXLoopback *ring, uint64_t frame, size_t count, const float *stereo);
void MXLoopbackRead(const MXLoopback *ring, int64_t frame, size_t count, float *stereo);
#endif
