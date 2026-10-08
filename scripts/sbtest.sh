#!/bin/sh
# Runs one diagnostic operation inside SpringBoard (diagnostic builds only) and prints its result plist.
# Usage: scripts/sbtest.sh <op> [key value]...
cd "$(dirname "$0")/.."
. scripts/device.sh
op=$1; shift
python3 - "$op" "$@" > ${NRSS_SCRATCH:-/tmp}/nrss-req.plist <<'PY'
import plistlib, sys
d = {'op': sys.argv[1]}
args = sys.argv[2:]
d.update(dict(zip(args[::2], args[1::2])))
sys.stdout.buffer.write(plistlib.dumps(d))
PY
dev_put ${NRSS_SCRATCH:-/tmp}/nrss-req.plist /tmp/nrss-test.plist
rm -f ${NRSS_SCRATCH:-/tmp}/nrss-req.plist
dev 'rm -f /tmp/nrss-test-result.plist; chmod 644 /tmp/nrss-test.plist; /tmp/nrss/nrss-notify com.aurelio.newsstandrss/test'
sleep "${NRSS_WAIT:-2}"
dev 'cat /tmp/nrss-test-result.plist' | python3 -c "import plistlib,sys,pprint; pprint.pprint(plistlib.loads(sys.stdin.buffer.read()), width=140)"
