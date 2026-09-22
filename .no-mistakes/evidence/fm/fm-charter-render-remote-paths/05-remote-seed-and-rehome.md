# Remote secondmate seed, driven end to end over the deterministic local SSH boundary

fake-ssh answers only the readiness doctor; every other call execs the real
bin/fm-remote-entrypoint.sh, which stages the real bin/fm-remote-home-provision.sh
through the real remote job worker. The charter shown below is the file the
remote mate actually obeys.

## A. The change (ddf1e44)

```
== parent home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/parent
== remote home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home (as '/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home' on host remote-linux)

$ FM_SECONDMATE_CHARTER='Own iOS delivery on the build host.' bin/fm-remote-home-seed.sh ios remote-linux <remote-root> /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home --no-projects
provisioned: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home projects=0
home=remote-linux:/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home
seed exit=0

--- the charter the remote mate actually reads: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/remote-home/data/charter.md ---
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<REMOTE-HOME>/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<REMOTE-HOME>/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<REMOTE-HOME>/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<REMOTE-HOME>/state/parent-route/ios.inbox'/NNN.msg '<REMOTE-HOME>/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<REMOTE-HOME>/state/parent-replies.status'`
parent-home paths left in the published remote charter (must be 0): 0

--- registry line ---
- ios - Own iOS delivery on the build host. (host: remote-linux; root: <REMOTE-ROOT>; home: <REMOTE-HOME>; scope: iOS implementation and validation; projects: ; added 2026-09-21)

== the build host is gone: retire the route (registry line + route state dropped)
registry lines left for ios: 0
durable charter data/ios/brief.md survives retirement: yes
  and it still names the retired host: 4

== bring the domain up on a replacement host home
$ bin/fm-remote-home-seed.sh ios remote-linux <remote-root> <replacement-home> --no-projects
provisioned: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/replacement-home projects=0
home=remote-linux:/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/head/replacement-home
re-seed exit=0

--- the charter the REHOMED mate reads: <replacement-home>/data/charter.md ---
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<REPLACEMENT-HOME>/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<REPLACEMENT-HOME>/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<REPLACEMENT-HOME>/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<REPLACEMENT-HOME>/state/parent-route/ios.inbox'/NNN.msg '<REPLACEMENT-HOME>/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<REPLACEMENT-HOME>/state/parent-replies.status'`
retired-host paths left in the rehomed charter (must be 0): 0
parent-home paths left in the rehomed charter (must be 0): 0
```

## B. Before the publish-time normalization (990e590 - renderer fix only)

```
== parent home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/parent
== remote home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home (as '/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home' on host remote-linux)

$ FM_SECONDMATE_CHARTER='Own iOS delivery on the build host.' bin/fm-remote-home-seed.sh ios remote-linux <remote-root> /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home --no-projects
provisioned: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home projects=0
home=remote-linux:/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home
seed exit=0

--- the charter the remote mate actually reads: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/remote-home/data/charter.md ---
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<REMOTE-HOME>/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<REMOTE-HOME>/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<REMOTE-HOME>/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<REMOTE-HOME>/state/parent-route/ios.inbox'/NNN.msg '<REMOTE-HOME>/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<REMOTE-HOME>/state/parent-replies.status'`
parent-home paths left in the published remote charter (must be 0): 0

--- registry line ---
- ios - Own iOS delivery on the build host. (host: remote-linux; root: <REMOTE-ROOT>; home: <REMOTE-HOME>; scope: iOS implementation and validation; projects: ; added 2026-09-21)

== the build host is gone: retire the route (registry line + route state dropped)
registry lines left for ios: 0
durable charter data/ios/brief.md survives retirement: yes
  and it still names the retired host: 4

== bring the domain up on a replacement host home
$ bin/fm-remote-home-seed.sh ios remote-linux <remote-root> <replacement-home> --no-projects
provisioned: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/replacement-home projects=0
home=remote-linux:/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/prefix/replacement-home
re-seed exit=0

--- the charter the REHOMED mate reads: <replacement-home>/data/charter.md ---
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<RETIRED-HOME>/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<RETIRED-HOME>/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<RETIRED-HOME>/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<RETIRED-HOME>/state/parent-route/ios.inbox'/NNN.msg '<RETIRED-HOME>/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<RETIRED-HOME>/state/parent-replies.status'`
retired-host paths left in the rehomed charter (must be 0): 4
parent-home paths left in the rehomed charter (must be 0): 0
```

B is the regression the round-1 decision asked to fix: the rehomed mate on the
replacement host is told to append every captain-facing line to, and read its
steers from, the host that was just retired. A names the replacement host.

Retirement in this lab is applied exactly as `bin/fm-teardown.sh` applies it to a
remote route - the registry line and the route's state files go, `data/<id>/brief.md`
stays (`bin/fm-teardown.sh:931-936`). The same sequence driven through the real
`bin/fm-teardown.sh` is `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`'s closing
case, "re-seeding a retired id onto a replacement host publishes the destination
host's paths", which passed in this run.
