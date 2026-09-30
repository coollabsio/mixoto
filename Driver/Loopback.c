#include "Loopback.h"
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");
_Static_assert(sizeof(float) * MX_CHANNELS == sizeof(uint64_t), "stereo float32 layout");
_Static_assert((MX_RING_FRAMES & (MX_RING_FRAMES - 1)) == 0, "ring must be a power of two");

void MXLoopbackReset(MXLoopback *ring) {
    for (size_t i = 0; i < MX_RING_FRAMES; ++i) {
        atomic_store_explicit(&ring->frames[i].frame, UINT64_MAX, memory_order_seq_cst);
        atomic_store_explicit(&ring->frames[i].stereo, 0, memory_order_seq_cst);
    }
}

void MXLoopbackWrite(MXLoopback *ring, uint64_t frame, size_t count, const float *stereo) {
    // HAL calls WriteMix for the final mixed device output, not for each writer.
    // Only one WriteMix callback writes a given device cycle. Input clients can
    // read concurrently without consuming or modifying the ring.
    for (size_t i = 0; i < count; ++i) {
        MXFrame *slot = &ring->frames[(frame + i) & (MX_RING_FRAMES - 1)];
        uint64_t bits;
        memcpy(&bits, stereo + i * MX_CHANNELS, sizeof(bits));
        // All three fields and both reader tag checks share one atomic order.
        // This avoids a torn stereo pair or a stale tag paired with new audio
        // during wraparound. No locks, allocation, or logging in this path.
        atomic_store_explicit(&slot->frame, UINT64_MAX, memory_order_seq_cst);
        atomic_store_explicit(&slot->stereo, bits, memory_order_seq_cst);
        atomic_store_explicit(&slot->frame, frame + i, memory_order_seq_cst);
    }
}

void MXLoopbackRead(const MXLoopback *ring, int64_t frame, size_t count, float *stereo) {
    for (size_t i = 0; i < count; ++i) {
        uint64_t bits = 0;
        int64_t wanted = frame + (int64_t)i;
        if (wanted >= 0) {
            const MXFrame *slot = &ring->frames[(uint64_t)wanted & (MX_RING_FRAMES - 1)];
            uint64_t before = atomic_load_explicit(&slot->frame, memory_order_seq_cst);
            uint64_t value = atomic_load_explicit(&slot->stereo, memory_order_seq_cst);
            uint64_t after = atomic_load_explicit(&slot->frame, memory_order_seq_cst);
            if (before == (uint64_t)wanted && after == before) { bits = value; }
        }
        memcpy(stereo + i * MX_CHANNELS, &bits, sizeof(bits));
    }
}
