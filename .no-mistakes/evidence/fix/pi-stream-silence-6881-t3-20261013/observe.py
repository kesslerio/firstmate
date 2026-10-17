import glob,os,time
seen={}
while True:
    for root in glob.glob('/tmp/fm-test-run.*/w*/tmp/fm-watch-triage-tests.*')+glob.glob('/tmp/fm-watch-triage-tests.*'):
        for case in glob.glob(root+'/*'):
            for path in [case+'/watch.out',case+'/state/.wake-queue']:
                try:
                    value=open(path).read()
                except OSError:
                    continue
                if value.strip() and seen.get(path)!=value:
                    print(os.path.relpath(path,root)+':\n'+value,flush=True)
                    seen[path]=value
    time.sleep(.05)
