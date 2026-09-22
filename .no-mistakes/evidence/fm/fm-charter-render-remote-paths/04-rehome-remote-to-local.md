### Remote -> local rehome: a retired remote route's durable charter is seeded as a LOCAL mate

Operator commands (identical for both variants):
```
$ FM_SECONDMATE_CHARTER='Own iOS delivery.' FM_SECONDMATE_REMOTE_HOME=/retired-host/mates/ios bin/fm-brief.sh ios --secondmate --no-projects
$ bin/fm-home-seed.sh ios <local-subhome> --no-projects
```

```
#### variant=head   (bin/fm-home-seed.sh from the head tree)
published charter: <local-subhome>/data/charter.md
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<PARENT-HOME>/state/ios.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<PARENT-HOME>/state/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<PARENT-HOME>/state/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<PARENT-HOME>/state/ios.inbox'/NNN.msg '<PARENT-HOME>/state/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<PARENT-HOME>/state/ios.status'`
  retired-host (/retired-host/mates/ios) mentions in the PUBLISHED charter: 0
  retired-host mentions in the DURABLE parent charter data/ios/brief.md: 4

#### variant=base   (bin/fm-home-seed.sh from the base tree)
published charter: <local-subhome>/data/charter.md
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '/retired-host/mates/ios/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '/retired-host/mates/ios/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/retired-host/mates/ios/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/retired-host/mates/ios/state/parent-route/ios.inbox'/NNN.msg '/retired-host/mates/ios/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '/retired-host/mates/ios/state/parent-replies.status'`
  retired-host (/retired-host/mates/ios) mentions in the PUBLISHED charter: 4
  retired-host mentions in the DURABLE parent charter data/ios/brief.md: 4

```

base = 8c1cdb7 (before the change): the local mate is told to read steers from, and append every captain-facing line to, a host that no longer exists - the silent misrouting this change exists to eliminate.
head = ddf1e44 (the change): publishing renders this destination's own paths, and the durable parent charter keeps the old host's text untouched.
