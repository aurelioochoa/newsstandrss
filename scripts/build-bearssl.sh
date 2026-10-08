#!/bin/sh
# Cross-compiles vendor/bearssl (v0.6) into vendor/build/libbearssl.a for armv7 / iOS 6.
set -e
cd "$(dirname "$0")/.."
THEOS=${THEOS:-/home/aurelio/theos}
CC="$THEOS/toolchain/linux/iphone/bin/clang"
LIBTOOL="$THEOS/toolchain/linux/iphone/bin/libtool"
SDK="$THEOS/sdks/iPhoneOS10.3.sdk"
OUT=vendor/build
if [ ! -d vendor/bearssl/src ]; then
	echo "vendor/bearssl is missing: run 'git submodule update --init'" >&2
	exit 1
fi
mkdir -p "$OUT/obj"
find vendor/bearssl/src -name '*.c' | while read -r src; do
	obj="$OUT/obj/$(echo "$src" | sed 's|vendor/bearssl/src/||; s|/|_|g; s|\.c$|.o|')"
	[ "$obj" -nt "$src" ] && continue
	"$CC" -target armv7-apple-ios6.0 -isysroot "$SDK" -Os -fPIC -Ivendor/bearssl/inc -Ivendor/bearssl/src \
		-Wno-deprecated -c "$src" -o "$obj" 2>&1 | grep -v "deprecated\|simulator" || true
done
rm -f "$OUT/libbearssl.a"
"$LIBTOOL" -static -o "$OUT/libbearssl.a" "$OUT"/obj/*.o 2>&1 | grep -v "has no symbols" || true
echo "built $OUT/libbearssl.a"
