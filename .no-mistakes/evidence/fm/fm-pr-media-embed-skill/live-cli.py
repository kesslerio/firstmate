import subprocess, tempfile, pathlib, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M46Z789HH26VTFDG91BQ3BY8')
fixture=pathlib.Path(tempfile.mkdtemp(prefix='.media-live-',dir=root))
sha='87893ad6ae2363565edf9589454a9f5e2c9dc1a5'
base=f'https://github.com/kunchenguid/firstmate/raw/{sha}/'
cases=[
('pinned-image',f'![Banner]({base}assets/banner.png)',0),
('missing-evidence','Evidence: screenshot.png',1),
('empty-required','Evidence pending',1),
('absent-path',f'![Missing]({base}assets/no-such-media-01M46.png)',1),
('relative-path','![Banner](assets/banner.png)',1),
('moving-ref','![Banner](https://github.com/kunchenguid/firstmate/raw/main/assets/banner.png)',1),
('abbreviated-ref',f'![Banner](https://github.com/kunchenguid/firstmate/raw/{sha[:7]}/assets/banner.png)',1),
('blob-image',f'![Banner](https://github.com/kunchenguid/firstmate/blob/{sha}/assets/banner.png)',1),
('public-raw-image',f'![Banner](https://raw.githubusercontent.com/kunchenguid/firstmate/{sha}/assets/banner.png)',0),
('non-image-bytes',f'![Fake image]({base}README.md)',1),
('code-is-not-evidence',f'```markdown\n![Banner]({base}assets/banner.png)\n```',1),
('unreadable-pr','Evidence',2),
]
try:
 with (evidence/'live-cli.txt').open('w') as log:
  for name,body,expected in cases:
   f=fixture/(name+'.md'); f.write_text(body)
   cmd=['bash','bin/fm-pr-media.sh','999999999' if name=='unreadable-pr' else '141','--repo','kunchenguid/firstmate','--body-file',str(f),'--require-embeds']
   r=subprocess.run(cmd,text=True,capture_output=True,timeout=90)
   log.write(f'CASE {name}: expected={expected} observed={r.returncode}\n'+r.stdout+r.stderr+'\n')
   log.flush()
   print(name,r.returncode,'PASS' if r.returncode==expected else 'FAIL',flush=True)
  for flag in ['--shape-only','--head','--attach']:
   r=subprocess.run(['bash','bin/fm-pr-media.sh','141',flag],text=True,capture_output=True)
   log.write(f'CASE removed flag {flag}: expected=2 observed={r.returncode}\n')
   print(flag,r.returncode,flush=True)
  r=subprocess.run(['bash','bin/fm-pr-media.sh','141','--repo','kunchenguid/firstmate','--require-embeds'],capture_output=True,text=True,timeout=90)
  log.write(f'CASE real published PR141: observed={r.returncode}\n'+r.stdout+r.stderr)
  print('published-body',r.returncode,flush=True)
finally:
 shutil.rmtree(fixture)
