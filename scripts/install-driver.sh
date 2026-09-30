#!/bin/sh
# Installs only our named HAL bundle. Run with administrator access, either
# from the app's explicit Install button or with sudo from Terminal.
# Restarts coreaudiod so macOS loads or unloads the driver now; launchd starts
# it again. System audio stops for a few seconds. Does not change defaults.
set -eu
HAL=/Library/Audio/Plug-Ins/HAL
DEST="$HAL/MixotoAudio.driver"
ID=local.mixoto.audio
LEGACY="$HAL/OpenMixerAudio.driver"
STAGE=
BACKUP=
check_bundle() {
    test -d "$1" && test ! -L "$1" &&
      test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist")" = "$ID"
}
if test "$(/usr/bin/id -u)" != 0; then
    echo 'Administrator access is required. Use the Install button or sudo.' >&2
    exit 1
fi
if test "$#" != 1; then
    echo 'Usage: install-driver.sh PATH/TO/MixotoAudio.driver | --uninstall' >&2
    exit 1
fi
if test -L "$HAL"; then echo 'Refusing a linked HAL directory.' >&2; exit 1; fi
if test -e "$DEST" || test -L "$DEST"; then
    check_bundle "$DEST" || { echo 'Refusing to replace an unknown or linked driver.' >&2; exit 1; }
fi
if test "$1" = --uninstall; then
    if test -d "$DEST"; then /bin/rm -rf "$DEST"; fi
    /usr/bin/killall coreaudiod || true
    echo 'Mixoto driver removed. Core Audio restarted.'
    exit 0
fi
check_bundle "$1" || { echo 'Not a Mixoto audio driver bundle.' >&2; exit 1; }
# Replace the old product only during an explicit installation, never uninstall.
if test -e "$LEGACY" || test -L "$LEGACY"; then
    if test -L "$LEGACY" || test ! -d "$LEGACY" ||
       test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$LEGACY/Contents/Info.plist")" != local.openmixer.audio; then
        echo 'Refusing to replace an unknown or linked legacy driver.' >&2
        exit 1
    fi
fi
/usr/bin/codesign --verify --strict "$1"
/bin/mkdir -p "$HAL"
STAGE=$(/usr/bin/mktemp -d "$HAL/.mixoto-install.XXXXXX")
cleanup() {
    if test -n "$BACKUP" && test -d "$BACKUP" && test ! -e "$DEST"; then /bin/mv "$BACKUP" "$DEST"; fi
    if test -n "$STAGE" && test -d "$STAGE"; then /bin/rm -rf "$STAGE"; fi
}
trap cleanup EXIT
/usr/bin/ditto --noqtn "$1" "$STAGE/MixotoAudio.driver"
/usr/bin/codesign --verify --strict "$STAGE/MixotoAudio.driver"
/usr/sbin/chown -R root:wheel "$STAGE/MixotoAudio.driver"
/bin/chmod -R 'u+rwX,go+rX,go-w' "$STAGE/MixotoAudio.driver"
if test -d "$DEST"; then
    BACKUP="$STAGE/previous.driver"
    /bin/mv "$DEST" "$BACKUP"
fi
/bin/mv "$STAGE/MixotoAudio.driver" "$DEST"
if test -d "$LEGACY"; then /bin/rm -rf "$LEGACY"; fi
/usr/bin/killall coreaudiod || true
echo 'Mixoto Stream Mix installed. Core Audio restarted.'
