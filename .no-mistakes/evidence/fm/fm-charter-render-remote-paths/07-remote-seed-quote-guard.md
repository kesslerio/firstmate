# Adversarial: a destination home the published charter could not render safely is refused

```
$ bin/fm-remote-home-seed.sh quoted remote-linux <remote-root> "/srv/ho'me/ios" --no-projects
exit=1
error: remote home must not contain a single quote: the published charter renders it into shell commands
route lines written to the registry despite the refusal: 0
durable charter scaffolded despite the refusal: no
```

A single quote in the destination home would be re-read out of the published
charter's shell-quoted paths at the next rehome, so the seed stops before the
route or the durable charter exists.
