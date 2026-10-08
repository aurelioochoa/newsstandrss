#!/bin/sh
# Compile and run the speech integration tests on the USB-connected iOS 6 phone.
set -eu
cd "$(dirname "$0")/.."
. scripts/device.sh
nrss_theos=${THEOS:-/home/aurelio/theos}
nrss_test_dir=$(mktemp -d /tmp/nrss-speech.XXXXXX)
nrss_compiler=$nrss_theos/toolchain/linux/iphone/bin/clang
nrss_sdk=$nrss_theos/sdks/iPhoneOS10.3.sdk
"$nrss_compiler" -target armv7-apple-ios6.0 -isysroot "$nrss_sdk" -fobjc-arc -Iapp \
    -c tests/speech.m -o "$nrss_test_dir/tests.o"
"$nrss_compiler" -target armv7-apple-ios6.0 -isysroot "$nrss_sdk" -fobjc-arc \
    -c app/NRSSSpeechReader.m -o "$nrss_test_dir/reader.o"
"$nrss_compiler" -target armv7-apple-ios6.0 -isysroot "$nrss_sdk" -framework Foundation -Wl,-w \
    "$nrss_test_dir/tests.o" "$nrss_test_dir/reader.o" -o "$nrss_test_dir/nrss-speech-tests"
"$nrss_theos/toolchain/linux/iphone/bin/ldid" -S "$nrss_test_dir/nrss-speech-tests"
dev_put "$nrss_test_dir/nrss-speech-tests" /tmp/nrss-speech-tests
dev 'chmod 755 /tmp/nrss-speech-tests; su mobile -c /tmp/nrss-speech-tests'
if [ "${1:-}" = "--ui" ]; then
    "$nrss_compiler" -target armv7-apple-ios6.0 -isysroot "$nrss_sdk" -Wl,-w \
        tests/notify.c -o tests/nrss-notify
    "$nrss_theos/toolchain/linux/iphone/bin/ldid" -S tests/nrss-notify
    python3 tests/reader-speech.py
fi
