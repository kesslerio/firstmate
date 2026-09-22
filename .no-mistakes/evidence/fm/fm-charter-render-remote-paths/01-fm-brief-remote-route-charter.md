### Remote-route charter scaffolded by the operator command
```
$ FM_HOME=<parent-home> FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
    FM_SECONDMATE_REMOTE_HOME=/srv/homes/ios \
    bin/fm-brief.sh ios --secondmate --no-projects
```

Parent home on this machine: /var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T//fm-charter-live.2biUdD/parent
Remote home named at scaffold: /srv/homes/ios

#### Every parent-channel / steering-inbox line in the rendered charter
```
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '/srv/homes/ios/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '/srv/homes/ios/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/srv/homes/ios/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/srv/homes/ios/state/parent-route/ios.inbox'/NNN.msg '/srv/homes/ios/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '/srv/homes/ios/state/parent-replies.status'`
```

#### Count of parent-home absolute paths left in the charter (must be 0)
```
matches for '/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T//fm-charter-live.2biUdD/parent/state': 0
```
