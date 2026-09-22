### Adversarial: a remote home that cannot be rendered safely must stop the scaffold before anything is written
```
$ FM_SECONDMATE_REMOTE_HOME=mates/alpha bin/fm-brief.sh g-relative --secondmate --no-projects
exit=1
error: FM_SECONDMATE_REMOTE_HOME must be an absolute path on the remote host: mates/alpha
brief written: no
---
$ FM_SECONDMATE_REMOTE_HOME=$'/mates/two\nlines' bin/fm-brief.sh g-newline --secondmate --no-projects
exit=1
error: FM_SECONDMATE_REMOTE_HOME must not contain a newline
brief written: no
---
$ FM_SECONDMATE_REMOTE_HOME=/mates/o'brien bin/fm-brief.sh g-quote --secondmate --no-projects
exit=1
error: FM_SECONDMATE_REMOTE_HOME must not contain a single quote: the charter renders it into shell commands, and a seed republishing that charter reads the path back out of them
brief written: no
---
$ FM_SECONDMATE_REMOTE_HOME=/mates/alpha bin/fm-brief.sh g-ship some-proj --mode no-mistakes
exit=1
error: FM_SECONDMATE_REMOTE_HOME applies only to --secondmate charters
brief written: no
---
```
