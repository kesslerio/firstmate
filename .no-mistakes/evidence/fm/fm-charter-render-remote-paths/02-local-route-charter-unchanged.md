# A local-route charter is unchanged by this change

Driven on both commits with the same command, into homes normalized to `<HOME>`:
```
$ FM_SECONDMATE_CHARTER='Own web delivery.' bin/fm-brief.sh web --secondmate --no-projects
```

## diff base 8c1cdb7 vs change ddf1e44
```
(no differences - byte-identical)
```

## The parent-channel lines a local mate still gets
```
22:Nobody reads this chat: the captain and the main firstmate see only what is appended to '<HOME>/state/web.status', and a captain-facing sentence that is not appended there has not been sent.
42:Firstmate steers you through durable message files in '<HOME>/state/web.inbox'.
43:When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '<HOME>/state/web.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '<HOME>/state/web.inbox'/NNN.msg '<HOME>/state/web.inbox'/handled/`.
49:   `echo "{state} [at=<epoch>]: {one short line}" >> '<HOME>/state/web.status'`
```

No `parent-replies.status` or `parent-route/` path appears on a local route: those
surfaces exist only on a remote host, and the parent home's own state paths are the
real ones a local mate reads and answers on.
