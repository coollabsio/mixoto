#!/usr/bin/env python3
"""Measure isolated pulse delay in a simultaneous two-channel PCM recording.

Left = reference; right = routed return. This is not a live latency estimate.
Use the same recording clock for both channels. Do not use music or speech.
"""
import argparse
import array
import json
import math
import statistics
import sys
import wave


def read_pcm(path):
    with wave.open(str(path), "rb") as recording:
        if recording.getnchannels() != 2 or recording.getsampwidth() != 2:
            raise ValueError("Use a stereo 16-bit PCM WAV: left reference, right return.")
        rate = recording.getframerate()
        frames = recording.getnframes()
        if not 8000 <= rate <= 192000 or frames > rate * 120:
            raise ValueError("Use 8–192 kHz audio, no more than 120 seconds.")
        samples = array.array("h", recording.readframes(frames))
        if sys.byteorder != "little":
            samples.byteswap()
        return rate, list(samples[0::2]), list(samples[1::2])


def pulse_peaks(samples, rate):
    if not samples:
        raise ValueError("Empty recording.")
    peak = max(abs(sample) for sample in samples)
    if peak < 500:
        raise ValueError("Signal too quiet or absent.")
    if peak >= 32760:
        raise ValueError("Signal clipped. Record again with lower gain.")
    baseline = samples[:int(rate * 0.05)]
    noise = math.sqrt(sum(sample * sample for sample in baseline) / len(baseline))
    if noise > peak * 0.02:
        raise ValueError("Start with at least 50 ms of silence. Noise is too high.")
    threshold = peak * 0.2
    result = []
    index = len(baseline)
    window = max(1, int(rate * 0.01))
    quiet_gap = int(rate * 0.25)
    while index < len(samples):
        if abs(samples[index]) >= threshold:
            end = min(index + window, len(samples))
            result.append(max(range(index, end), key=lambda i: abs(samples[i])))
            index += quiet_gap
        else:
            index += 1
    if len(result) < 5:
        raise ValueError("Record at least five isolated pulses, one second apart.")
    return result


def measure(path):
    rate, reference, routed = read_pcm(path)
    left = pulse_peaks(reference, rate)
    right = pulse_peaks(routed, rate)
    if len(left) != len(right):
        raise ValueError("Pulse counts differ. Dropout, noise, or recording cut short.")
    delay = [(b - a) * 1000 / rate for a, b in zip(left, right)]
    if any(value < 0 or value > 500 for value in delay):
        raise ValueError("Pulse alignment failed. Expected a return delay of 0–500 ms.")
    ordered = sorted(delay)
    return {
        "method": "isolated-pulse peak difference; same recording clock",
        "sample_rate": rate,
        "pulse_count": len(delay),
        "median_ms": statistics.median(delay),
        "p95_ms": ordered[math.ceil(len(ordered) * 0.95) - 1],
        "min_ms": min(delay),
        "max_ms": max(delay),
        "sample_resolution_ms": 1000 / rate,
        "scope": "recorded reference-to-return path; includes capture and hardware delays",
        "delays_ms": delay,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording")
    args = parser.parse_args()
    try:
        print(json.dumps(measure(args.recording), indent=2))
    except (ValueError, wave.Error, OSError, EOFError) as error:
        parser.exit(1, f"Cannot measure delay: {error}\n")


if __name__ == "__main__":
    main()
