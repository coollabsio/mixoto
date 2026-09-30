#include "../Loopback.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static MXLoopback ring;
static _Atomic uint64_t progress;
enum { STRESS_FRAMES = 200000 };
static void *writer(void *unused) {
    (void)unused;
    for (uint64_t frame = 0; frame < STRESS_FRAMES; ++frame) {
        float value[2] = { (float)(frame + 1), -(float)(frame + 1) };
        MXLoopbackWrite(&ring, frame, 1, value);
        atomic_store(&progress, frame);
    }
    return NULL;
}
static void *reader(void *unused) {
    (void)unused;
    for (unsigned iteration = 0; iteration < STRESS_FRAMES; ++iteration) {
        uint64_t latest = atomic_load(&progress);
        // Both recent data and older positions that can race a ring wrap.
        uint64_t wanted = latest > 2 * MX_RING_FRAMES ? latest - 2 * MX_RING_FRAMES : latest;
        float value[2];
        MXLoopbackRead(&ring, (int64_t)wanted, 1, value);
        assert(value[0] == 0 || value[0] == (float)(wanted + 1));
        assert(value[1] == -value[0]);
    }
    return NULL;
}
int main(void) {
    MXLoopbackReset(&ring);
    float zeros[20];
    MXLoopbackRead(&ring, -5, 10, zeros);
    for (size_t i = 0; i < 20; ++i) { assert(zeros[i] == 0); }
    float source[1024], first[1024], second[1024];
    memset(source, 0, sizeof(source));
    source[100 * 2] = 0.75; source[100 * 2 + 1] = -0.25;
    // Write across the ring boundary. Two readers see the same stereo pairs.
    MXLoopbackWrite(&ring, MX_RING_FRAMES - 100, 512, source);
    MXLoopbackRead(&ring, MX_RING_FRAMES - 100, 512, first);
    MXLoopbackRead(&ring, MX_RING_FRAMES - 100, 512, second);
    assert(memcmp(first, source, sizeof(source)) == 0);
    assert(memcmp(second, first, sizeof(first)) == 0);
    MXLoopbackReset(&ring);
    MXLoopbackRead(&ring, MX_RING_FRAMES - 100, 512, first);
    for (size_t i = 0; i < 1024; ++i) { assert(first[i] == 0); }
    // Driver read timestamps are offset by MX_DELAY_FRAMES. Check actual PCM
    // impulse position, not only a declared property or arithmetic constant.
    MXLoopbackWrite(&ring, 0, 512, source);
    size_t found = 0;
    for (int64_t sample = 0; sample < MX_DELAY_FRAMES + 512; ++sample) {
        float pair[2];
        MXLoopbackRead(&ring, sample - MX_DELAY_FRAMES, 1, pair);
        if (pair[0] != 0) { assert(sample == MX_DELAY_FRAMES + 100); ++found; }
    }
    assert(found == 1);
    MXLoopbackReset(&ring);
    pthread_t producer, consumers[2];
    assert(pthread_create(&producer, NULL, writer, NULL) == 0);
    for (size_t i = 0; i < 2; ++i) { assert(pthread_create(&consumers[i], NULL, reader, NULL) == 0); }
    assert(pthread_join(producer, NULL) == 0);
    for (size_t i = 0; i < 2; ++i) { assert(pthread_join(consumers[i], NULL) == 0); }
    puts("Ring boundary, reset, stereo, multi-reader, impulse-delay, and concurrent wrap tests passed.");
    return 0;
}
