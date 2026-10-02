# Contributions compatibility: product evidence

Validated checkout: be28c69c763f20b3211b48652462e2e7635adc30.

The baseline script polled public PR 5645 using real gh 2.45.0 and recorded an unavailable error. Direct CLI readback confirmed `unknown flag: --slurp`. The target script polled the same PR successfully, retaining its observed head and 21 check results. The disposable binary matched the official release SHA-256: 79e89a14af6fc69163aee00e764e86d5809d0c6c77e6f229aebe7a4ed115ee67.

The real contributions CLI, real jq, and real gh 2.45.0/2.83.2 were exercised against a disposable TLS API server with synthetic records and actual HTTP Link pagination. The server replaced the data service, not the product or CLI. A disposable token and process-scoped certificate trust kept real credentials out of this server. Exact CLI outputs, timings, HTTP requests, and persisted records are in live-api-transcript.json and api-*.json.

Later-page comments, reviews, inline activity, check runs, and legacy statuses were observed successfully. Nonmember comments were filtered. PR replay and acknowledgement did not duplicate durable wakes. Issue polling observed later-page maintainer comments and ready-label transitions without replaying them. Slow reads preserved prior records and wake queues. Genuine outages recorded an error once per episode, successful reads cleared it, and malformed JSON produced an assembly failure.

Read-only GitHub metadata confirms the existing PR retains its descriptive title and is open/unmerged and mergeable. Its published head differs from this gate checkout and trails the supplied base by one commit (merge base 241d4617d6c160471d7da8ffe637b59f8f4a7af9). The gate checkout itself contains the supplied base. This Test phase did not publish the gate head or rebind an attestation: Push, PR, and CI remain owned by the outer executor. Final delivery is pending those phases. No merge or forge mutation was attempted.

The contributions and Pi branch test files completed successfully. The PR-security suite initially encountered a restricted PATH assumption; with FM_TEST_BASE_PATH set to the existing PATH, it progressed through the affected watcher assertion and further checks but reached the chosen 180-second process bound before completing the whole file. The exact changed test_self_merge_and_poll_publish_one_outcome was then run alone and passed. No complete PR-security suite pass is claimed.

The remote trace suite initially recursively archived the worktree-local scratch directory and was stopped. With TAR_OPTIONS=--exclude=.test-scratch, it reached provisioning but failed because pre-existing remote worker identity routines require /bin/ps or /usr/bin/ps; neither exists on this NixOS host. A standalone execution of registered fm_test_cleanup proved removal of a fixture containing read-only directories. The remote suite remains unvalidated; run it on a host providing those supported absolute paths. No unrelated production or host repair was made.

Disposable servers and test processes were stopped. Scratch files, binaries, certificates, and temporary test selectors were removed. Evidence remains here. The affected product surface is CLI output and persisted records; no rendered UI changed.
