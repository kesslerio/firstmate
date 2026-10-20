# Reproducible live-capture procedure — Grok approval-titled composer (PR kunchenguid/firstmate#6132)

This is the exact procedure that produced the captures in this directory, and the
checklist a reviewer must apply to each capture. It is written so a reviewer on
another machine can reproduce the same evidence without any of this session's
context.

## 0. Version and environment

| Item | Value |
|---|---|
| Harness | `grok` — Grok Build TUI, xAI official npm package `@xai-official/grok` |
| Version captured | **grok 1.0.62 (1474f9cbdd91) [stable]** |
| Host | zeppola, Linux x86_64, NixOS |
| Terminal multiplexer | **tmux 3.6a**, private socket only (`tmux -L fm-lab`), never the default server |
| Terminal size | **120x40** for the primary capture; 80x30 and 220x50 as width checks |
| Login | the machine's **existing** Grok login (`~/.grok`, OIDC). No credential was copied, requested, or synthesized; no sign-in, sign-out, re-login, or credential-store edit was performed |
| Prompts | **none submitted** — no model tokens were spent |

The prior record on this PR was captured on **grok 1.0.46 (2765805b9442) [stable]**
on 2026-10-02. It is prior evidence, not fresh evidence for this head.

## 1. Why the Grok home must NOT be isolated

An **isolated** `GROK_HOME` (or an isolated `HOME`) contains no login, so the CLI
stops at its sign-in screen and the run cannot reach a composer. That is what
made an earlier attempt inconclusive. `XAI_API_KEY` is not required and is not
the issue.

Launch the CLI with the machine's **existing** Grok home so its existing OIDC
login is present. Set only `FM_HOME` to the disposable lab.

## 2. Launch

```bash
cd <repo-root>                      # the PR worktree
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB"     # marked disposable firstmate lab home
mkdir -p "$LAB/tmux"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" \
  tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" \
      -e FM_HOME="$LAB" grok --always-approve --reasoning-effort high
```

`--always-approve` is what puts `· always-approve` in the composer title.
`--reasoning-effort high` is what puts `(high)` in it.

## 3. Read the pane through the real Firstmate terminal interface

The library's own `tmux` calls are bare, so address the lab socket with a PATH
shim, exactly as `tests/fm-composer-matrix-live-e2e.test.sh` does:

```bash
SHIM_DIR="$LAB/shim"; mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$(command -v tmux)" -L fm-lab "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"; export TMUX_TMPDIR="$LAB/tmux"

. "$PWD/bin/fm-composer-lib.sh"     # the shared classifier
. "$PWD/bin/fm-tmux-lib.sh"         # fm_tmux_composer_state, fm_pane_input_pending
. "$PWD/bin/fm-backend.sh"          # fm_backend_composer_state
```

## 4. The composer shape to capture

Grok 1.0.62 draws the composer as a **rounded** box. The approval mode and the
model/effort live on the **bottom border**, inside the rule, at exactly the
aligned width of the box:

```
  ╭──────────────────────────────────────────────────────────────────────────────────╮
  │ ❯                                                                            │
  ╰─────────────────────────────────────────────── Grok 4.7 (high) · always-approve ─╯
```

The cursor parks on the **content row** (`❯` row), row 35 of a 120x40 pane.
The mid-dot between `(high)` and `always-approve` is `U+00B7` (`·`).

## 5. The cases to capture, and what the reviewer must check in each

### Case A — idle (live)

1. Launch, wait for the composer to render (≈1s on this host).
2. Capture: `tmux -L fm-lab capture-pane -e -p -t primary > idle-120x40.ansi`
   (and the same without `-e` for `idle-120x40.txt`).
3. Read the verdicts:
   ```bash
   fm_tmux_composer_state primary        # expect: empty
   fm_pane_input_pending primary         # expect: non-zero (input-guard: defer/allow semantics)
   fm_backend_composer_state tmux primary  # expect: empty
   ```

**Reviewer checks**
- The captured pane shows the rounded box with `Grok 4.7 (high) · always-approve`
  on the **bottom** border, and an **empty** content row (the `❯` glyph with no
  typed text).
- The transcript shows `tmux=empty`, `dispatcher=empty`, `input-guard=allow`.
- The transcript shows the cursorless re-read of the *same* capture through the
  herdr (`styled=1`) and cmux/orca (`styled=0`) capability profiles also
  `empty`. These are capability-profile re-reads of a real capture — **not**
  launches of Herdr/cmux/orca.
- The same must hold at 80x30 and 220x50 (`idle-80x30`, `idle-220x50`).

### Case B — draft (live)

1. `tmux -L fm-lab send-keys -t primary -l "draft for composer safety validation"`
   — **no Enter**. The draft must remain unsubmitted.
2. Capture and read exactly as in Case A.

**Reviewer checks**
- The captured pane shows the text `draft for composer safety validation` in the
  content row, still inside the same rounded approval-titled box.
- The transcript shows `tmux=pending`, `dispatcher=pending`, `input-guard=defer`
  — a draft must never authorise injection.
- The cursorless re-read of the same capture shows `pending` as well.
- The same must hold at 80x30 and 220x50.

### Case C — cleared (live)

1. Send `BSpace` repeatedly to clear the draft, capture, and read.

**Reviewer checks**
- The transcript shows `tmux=empty`, `input-guard=allow` again — clearing the
  draft restores the guard's permission.

### Case D — malformed and unproven families (CONTROLLED terminal inputs)

These are **not** a Grok release's rendering. They are written fixtures rendered
in real tmux panes and read through the **real** adapter
(`fm_tmux_composer_state`, `fm_pane_input_pending`,
`fm_backend_composer_state tmux`). They must be labelled as controlled inputs.

Render, for each variant, the same three-row box with the variant's border
family or title:

| Variant | Expected verdict |
|---|---|
| rounded box + `Grok 4.7 (high) · always-approve` | `empty` / allow |
| **light** box `┌ ┐ │ ─ └ ┘` + the same title | `unknown` / defer |
| **heavy** box `┏ ┓ ┃ ━ ┗ ┛` + the same title | `unknown` / defer |
| **double** box `╔ ╗ ║ ═ ╚ ╝` + the same title | `unknown` / defer |
| **ASCII** box `+ + | - + +` + the same title | `unknown` / defer |
| title `Grok 4.7 (high) · auto-approve` | `unknown` / defer |
| title `Grok 4.7 (high) · always-approve now` | `unknown` / defer |
| title `Other 4.7 (high) · always-approve` | `unknown` / defer |
| title `Grok 4.7 (turbo) · always-approve` | `unknown` / defer |
| title `unknown surface · mode` | `unknown` / defer |
| title `Grok 4.7 (high) · always-approve · extra` | `unknown` / defer |
| title `Grok 4.7 (high) · always-approve` on the 1.0.5 three-column overhang | `unknown` / defer |
| legacy aligned typed title `Grok 4.6 (xhigh)`, no suffix | `empty` / allow |
| legacy 1.0.5 three-column overhang title `Grok 4.6 (xhigh)`, no suffix | `empty` / allow |

**Reviewer checks**
- The light/heavy/double/ASCII rows must read `unknown` and defer. This is the
  narrowing under review: on the previous published head (`7a49c661`) the
  light, heavy and double rows read `empty` and allowed injection. Compare
  against `terminal-interface-before-narrowing.txt`.
- The legacy rows must still read `empty`: the narrowing must not cost the
  previously supported title families.
- The overhang row carrying the approval suffix must read `unknown`: no
  overhang shape carrying that suffix has ever been observed.
- The 1.0.5 three-column overhang is **capture-only compatibility evidence** and
  has never been live-verified against a Grok release.

## 6. Rendering the reviewable artifacts

The `.ansi` files are the raw `tmux capture-pane -e -p` output. The `.html`
files are those captures converted to styled HTML, and the `.png` files are
screenshots of that HTML:

```bash
chromium --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=1 --screenshot=idle-120x40.png \
  --window-size=<cols*10+80>,<rows*20+150> "file://$PWD/idle-120x40.html"
```

These are **rendered captures of a real captured terminal grid**, not a native
screenshot of a live pane. They are labelled as such on the rendered page.

## 7. Cleanup

```bash
tmux -L fm-lab kill-server
rm -rf "$LAB"
```

Confirm no `grok`, `tmux`, or `chromium` process from the capture remains, and
that the lab directory is gone. The evidence directory itself is kept.

## 8. What a reviewer should conclude

1. On a current Grok (1.0.62), the rounded approval-titled composer reads
   `empty` when idle and `pending` when it holds an unsubmitted draft, through
   the real terminal interface and the real dispatcher.
2. The same aligned approval-titled box drawn in the light, heavy, double, or
   ASCII family reads `unknown` and defers — so the over-acceptance is closed
   at this head.
3. The previously supported legacy title families are unchanged.
