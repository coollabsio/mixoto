#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rtk proxy sh scripts/build-driver.sh
rtk proxy xcrun clang -std=c11 -Wall -Wextra -Werror \
  -framework CoreAudio -framework CoreFoundation Driver/Tests/DriverTests.c \
  -o artifacts/driver-tests
rtk proxy artifacts/driver-tests "$PWD/artifacts/MixotoAudio.driver" "$PWD/artifacts/driver-offline-probe.wav"
echo 'Delay probe below uses simulated HAL callbacks, not hardware or live system audio.'
rtk proxy python3 scripts/measure-delay.py artifacts/driver-offline-probe.wav
rtk proxy xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  Driver/Tests/LoopbackTests.c Driver/Loopback.c -o artifacts/loopback-tests
rtk proxy artifacts/loopback-tests
rtk proxy xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=thread \
  Driver/Tests/LoopbackTests.c Driver/Loopback.c -o artifacts/loopback-thread-tests
rtk proxy artifacts/loopback-thread-tests
