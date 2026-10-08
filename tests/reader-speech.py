# Run after installing a diagnostic build; uses temporary articles without changing feeds.
import argparse, pathlib, plistlib, subprocess, time, uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--bundle-id', help='Installed feed app; defaults to the first feed')
args=parser.parse_args()
def remote(command):
    return subprocess.check_output(['bash','-c','. scripts/device.sh; dev "$1"','bash',command],cwd=ROOT)
def put(path, target):
    subprocess.check_call(['bash','-c','. scripts/device.sh; dev_put "$1" "$2"','bash',str(path),target],cwd=ROOT)
def rpc(op, **args):
    token=str(uuid.uuid4())
    req=pathlib.Path('/tmp/nrss-reader-test.plist')
    req.write_bytes(plistlib.dumps(dict(op=op,requestID=token,**args)))
    put(req,'/tmp/nrss-reader-test.plist')
    remote('/tmp/nrss/nrss-notify com.aurelio.newsstandrss/reader-test')
    for n in range(25):
        try:
            result=plistlib.loads(remote('cat /tmp/nrss-reader-test-result.plist'))
            if result.get('requestID')==token:
                return result
        except (subprocess.CalledProcessError,plistlib.InvalidFileException):
            pass
        time.sleep(.2)
    raise RuntimeError('Reader did not respond to '+op)
def check(condition, label):
    if not condition: raise AssertionError(label)
    print('PASS:',label,flush=True)
def await_state(state):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        r=rpc('status')
        if r['state']==state: return r
        time.sleep(.15)
    raise AssertionError(('expected state',state,r))
remote('mkdir -p /tmp/nrss')
notifier=ROOT/'tests/nrss-notify'
if not notifier.exists():
    raise SystemExit('Build tests/nrss-notify from tests/notify.c first (see README).')
put(notifier,'/tmp/nrss/nrss-notify')
remote('chmod 755 /tmp/nrss/nrss-notify')
subprocess.check_call(['scripts/sbtest.sh','unlock'],cwd=ROOT,stdout=subprocess.DEVNULL)
bundle_id=args.bundle_id
if not bundle_id:
    feeds=plistlib.loads(remote('cat /var/mobile/Library/NewsstandRSS/Feeds.plist'))['feeds']
    if not feeds: raise SystemExit('Add a feed before running the reader UI test.')
    bundle_id='com.aurelio.newsstandrss.feed.'+feeds[0]['id']
subprocess.check_call(['scripts/sbtest.sh','launch','bundleID',bundle_id],cwd=ROOT,stdout=subprocess.DEVNULL)
rpc('back')
rpc('fixture')
time.sleep(1)
r=rpc('status')
check(r['playEnabled'] and not r['stopEnabled'] and not r['toolbarHidden'],'article has ready speech controls')
rpc('speed',index=0)
rpc('screenshot')
pathlib.Path('/tmp/nrss-reader-initial.png').write_bytes(remote('cat /tmp/nrss-reader-screen.png'))
rpc('toggle')
r=await_state(1)
check('Una noticia & su lectura' in r['spokenText'] and 'voz alta & los controles' in r['spokenText'],'reads rendered title and body with decoded entities')
check(not any(x in r['spokenText'] for x in ['METADATA_EXCLUDED','FEED_EXCLUDED','HIDDEN_EXCLUDED','Leer en el sitio web','Read on the Website']),'excludes metadata, hidden text and website button')
check(r['language']=='es' and r['playTitle'] in ['Pausar','Pause'] and r['stopEnabled'],'Spanish voice and pause button during playback')
rpc('toggle')
r=await_state(3)
check(r['playTitle'] in ['Reanudar','Resume'],'pause button switches to resume')
rpc('speed',index=2)
r=rpc('status')
check(r['state']==3 and r['speed']==2,'selecting 2× preserves paused state')
rpc('screenshot')
pathlib.Path('/tmp/nrss-reader-paused.png').write_bytes(remote('cat /tmp/nrss-reader-screen.png'))
rpc('toggle')
r=await_state(1)
check(r['speed']==2,'resume uses selected speed')
rpc('speed',index=1)
r=rpc('status')
check(r['state']==1 and r['speed']==1.5,'1.5× applies from the actual speed selector')
rpc('inactive')
r=await_state(3)
check(r['playTitle'] in ['Reanudar','Resume'],'leaving the foreground pauses reading')
rpc('toggle')
r=await_state(1)
r=rpc('stop')
check(r['state']==0 and not r['stopEnabled'] and r['playTitle'] in ['Leer en voz alta','Read Aloud'],'stop restores initial controls')
rpc('toggle')
r=await_state(1)
r=rpc('back')
check(r['state']==0 and r['toolbarHidden'],'leaving the article stops voice and hides speech toolbar')
rpc('fixture')
time.sleep(.5)
r=rpc('status')
check(r['speed']==1.5 and r['selectedSpeed']==1,'next article remembers speed')
rpc('speed',index=0)
rpc('back')
print('READER_UI_TESTS_PASSED',flush=True)
