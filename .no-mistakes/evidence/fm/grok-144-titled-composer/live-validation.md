# Grok approval-titled composer live validation

Real Grok 1.0.46 (2765805b9442) ran from the gate worktree in a marked disposable Firstmate home on a private fm-lab tmux socket, at 100x32, 80x28 and 120x36. The existing login was mounted read-only in a process-private namespace. No sign-in, credential edits, model prompts, production or fleet mutations occurred.

PNGs render actual ANSI terminal captures. Independent QA exercised draft/clear interactions and inspected the idle, draft and second-mid-dot screenshots; no visual issues were found.

The focused command bash tests/fm-composer-lib.test.sh passed. Historical 1.0.5 overhang and malformed brand/effort cases use portable fixtures, not live vendor evidence.

Tmux adapter and backend dispatcher results are live. Cursorless styled/plain results use the same real pane with capability profiles; native Herdr/cmux/orca backends were not launched. Baseline results use base commit 241d4617d6c160471d7da8ffe637b59f8f4a7af9 against that same pane.

## Supported idle, 100 columns

    cursor_row=27
    tmux_adapter=empty
    backend_dispatch=empty
    cursorless_styled_profile=empty
    cursorless_plain_profile=empty
    injection_guard=permit
    baseline_tmux_adapter=unknown
    baseline_cursorless_styled=unknown

## Unsubmitted draft

    cursor_row=27
    tmux_adapter=pending
    backend_dispatch=pending
    cursorless_styled_profile=pending
    cursorless_plain_profile=pending
    injection_guard=defer
    baseline_tmux_adapter=pending-unproven
    baseline_cursorless_styled=pending-unproven

## Supported idle, 80 columns

    cursor_row=23
    tmux_adapter=empty
    backend_dispatch=empty
    cursorless_styled_profile=empty
    cursorless_plain_profile=empty
    injection_guard=permit
    baseline_tmux_adapter=unknown
    baseline_cursorless_styled=unknown

## Supported idle, 120 columns

    cursor_row=31
    tmux_adapter=empty
    backend_dispatch=empty
    cursorless_styled_profile=empty
    cursorless_plain_profile=empty
    injection_guard=permit
    baseline_tmux_adapter=unknown
    baseline_cursorless_styled=unknown

## Normal mode without suffix

    cursor_row=27
    tmux_adapter=empty
    backend_dispatch=empty
    cursorless_styled_profile=empty
    cursorless_plain_profile=empty
    injection_guard=permit
    baseline_tmux_adapter=empty
    baseline_cursorless_styled=empty

## Unsupported plan suffix

    cursor_row=27
    tmux_adapter=unknown
    backend_dispatch=unknown
    cursorless_styled_profile=unknown
    cursorless_plain_profile=unknown
    injection_guard=defer
    baseline_tmux_adapter=unknown
    baseline_cursorless_styled=unknown

## Unsupported second mid-dot

    cursor_row=27
    tmux_adapter=unknown
    backend_dispatch=unknown
    cursorless_styled_profile=unknown
    cursorless_plain_profile=unknown
    injection_guard=defer
    baseline_tmux_adapter=unknown
    baseline_cursorless_styled=unknown

## Cleanup

Private tmux server stopped. Owned Grok process 4111231 and descendants stopped. Bounded screenshot processes stopped after writing PNGs. No remaining live processes referenced the lab. Disposable lab removed and final worktree status checked. Delivery, PR thread resolution and remote CI belong to the outer executor; none were driven in this Test phase.
