#!/bin/sh
# Switches the default output device back and forth while Mixoto runs, then
# checks that Mixoto's main thread is not stuck. Reproduces the hangs that
# connecting Bluetooth headphones caused (see .ai/lessons.md, 2026-11-09).
#
# Usage: sh scripts/stress-device-switch.sh [rounds] [other output device ID]
# Start Mixoto first. Audio switches between two outputs during the test;
# the original default output is restored at the end.
set -eu
ROUNDS=${1:-20}
PID=$(pgrep -f "Mixoto.app/Contents/MacOS/Mixoto" | head -1 || true)
[ -n "$PID" ] || { echo "Mixoto is not running." >&2; exit 1; }

TOOLS=$(mktemp -d)
trap 'rm -rf "$TOOLS"' EXIT
cat > "$TOOLS/output.swift" <<'EOF'
import CoreAudio
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
let system = AudioObjectID(kAudioObjectSystemObject)
var defaultOutput = address(kAudioHardwarePropertyDefaultOutputDevice)
if CommandLine.arguments.count > 1 {
    var id = AudioObjectID(CommandLine.arguments[1])!
    exit(AudioObjectSetPropertyData(system, &defaultOutput, 0, nil, 4, &id) == noErr ? 0 : 1)
}
// Without an argument: print the default output, then other real outputs.
var size: UInt32 = 4, current = AudioObjectID(0)
AudioObjectGetPropertyData(system, &defaultOutput, 0, nil, &size, &current)
print(current)
var all = address(kAudioHardwarePropertyDevices)
AudioObjectGetPropertyDataSize(system, &all, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(system, &all, 0, nil, &size, &ids)
for id in ids where id != current {
    var uid = address(kAudioDevicePropertyDeviceUID), value: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &uid, 0, nil, &size, &value) == noErr,
          let text = value?.takeRetainedValue() as String?,
          !text.contains("mixoto"), !text.hasPrefix("CADefaultDeviceAggregate") else { continue }
    var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    if AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 { print(id) }
}
EOF
swiftc -O "$TOOLS/output.swift" -o "$TOOLS/output"

DEVICES=$("$TOOLS/output")
ORIGINAL=$(echo "$DEVICES" | sed -n 1p)
OTHER=${2:-$(echo "$DEVICES" | sed -n 2p)}
[ -n "$OTHER" ] || { echo "Needs a second output device." >&2; exit 1; }
trap '"$TOOLS/output" "$ORIGINAL" || true; rm -rf "$TOOLS"' EXIT

# Stuck: the main thread runs Mixoto code and waits on a lock or queue.
stuck() {
    main=$(sample "$PID" 1 -mayDie 2>/dev/null | awk '/main-thread/{m=1; print; next} m&&/^    [0-9]+ Thread_/{exit} m')
    echo "$main" | grep -q "in Mixoto" &&
        echo "$main" | grep -qE "psynch_mutexwait|psynch_cvwait|dispatch_sync_f_slow|_dispatch_event_loop_wait_for_ownership"
}

echo "Switching output $ORIGINAL <-> $OTHER, $ROUNDS rounds."
i=1
while [ "$i" -le "$ROUNDS" ]; do
    "$TOOLS/output" "$OTHER"; sleep 2
    "$TOOLS/output" "$ORIGINAL"; sleep 2
    kill -0 "$PID" 2>/dev/null || { echo "FAIL: Mixoto exited in round $i." >&2; exit 1; }
    i=$((i + 1))
done
sleep 3
# A busy main thread is normal for a moment; stuck in two checks is a hang.
if stuck && sleep 3 && stuck; then
    echo "FAIL: Mixoto's main thread is stuck. Run: sample $PID 2" >&2; exit 1
fi
echo "PASS: Mixoto responded after $ROUNDS rounds."
