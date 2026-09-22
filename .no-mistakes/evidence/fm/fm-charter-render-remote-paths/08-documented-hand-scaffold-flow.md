# The documented hand-scaffold flow (docs/remote-secondmates.md, 'Provision a route')

The operator fills the charter by hand FIRST, naming the destination home, then seeds.
The seed finds the brief already present and skips scaffolding, so publishing is the
only thing standing between the durable charter and the mate.

```
== parent home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/parent
== remote home:  /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home (as '/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home' on host remote-linux)

== documented hand-scaffold flow (docs/remote-secondmates.md 'Provision a route')
$ FM_SECONDMATE_REMOTE_HOME=/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home bin/fm-brief.sh ios --secondmate --no-projects
scaffolded: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/parent/data/ios/brief.md (secondmate charter)

$ FM_SECONDMATE_CHARTER='Own iOS delivery on the build host.' bin/fm-remote-home-seed.sh ios remote-linux <remote-root> /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home --no-projects
provisioned: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home projects=0
home=remote-linux:/private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home
seed exit=0

--- the charter the remote mate actually reads: /private/var/folders/lw/83_wpdv92g5ff57h6hflw6wr0000gp/T/fm-charter-live.2biUdD/remote/handscaffold/remote-home/data/charter.md ---
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<REMOTE-HOME>/state/parent-replies.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<REMOTE-HOME>/state/parent-route/ios.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<REMOTE-HOME>/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<REMOTE-HOME>/state/parent-route/ios.inbox'/NNN.msg '<REMOTE-HOME>/state/parent-route/ios.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<REMOTE-HOME>/state/parent-replies.status'`
parent-home paths left in the published remote charter (must be 0): 0

--- registry line ---
- ios - Own iOS delivery on the build host. (host: remote-linux; root: <REMOTE-ROOT>; home: <REMOTE-HOME>; scope: iOS implementation and validation; projects: ; added 2026-09-21)
```
