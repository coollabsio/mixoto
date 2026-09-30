#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-driver.sh
xcrun clang -std=c11 -Wall -Wextra -Werror \
  -framework CoreAudio -framework CoreFoundation Driver/Tests/DriverTests.c \
  -o artifacts/driver-tests
artifacts/driver-tests "$PWD/artifacts/MixotoAudio.driver" "$PWD/artifacts/driver-offline-probe.wav"
echo 'Delay probe below uses simulated HAL callbacks, not hardware or live system audio.'
python3 scripts/measure-delay.py artifacts/driver-offline-probe.wav
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  Driver/Tests/LoopbackTests.c Driver/Loopback.c -o artifacts/loopback-tests
artifacts/loopback-tests
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=thread \
  Driver/Tests/LoopbackTests.c Driver/Loopback.c -o artifacts/loopback-thread-tests
artifacts/loopback-thread-tests
