# Completed Test repair and live validation

Validated target 5152397a05d3934aa645a71775e6b3f423834d08 with the existing repair in tests/fm-contributions.test.sh. It resolves the real date from PATH before installing pinned-clock shims and isolates Bearings in each fixture home/root. No further source changes were needed. validated-test-repair.patch and repair-test-hash.txt identify the tested bytes.

This turn regenerated live-transcript.json, live-results.json and scenario state evidence by executing the real contributions CLI with upstream gh 2.45.0 and installed gh 2.83.2 against a disposable local HTTP service. The routing wrapper changes endpoint locations; responses come through the genuine CLI. The base executable reproduced the compatibility failure; the changed executable consumed all PR and issue pages, filtered unrelated signals, delivered and acknowledged maintainer signals once, preserved coherent observations during malformed later pages, HTTP errors and head replacement, and bounded slow assembly without surviving children. Authenticated generated checks passed. Requests were read-only. Ten live scenarios passed.

Successful commands:

- timeout -k 5s 600s bash tests/fm-contributions.test.sh
- FM_TEST_BASE_PATH=/run/current-system/sw/bin timeout -k 5s 240s bash tests/fm-pr-check-security.test.sh
- timeout -k 5s 180s python3 live-drive.py, from this evidence directory
- timeout -k 5s 60s bash .test-scratch/pi-consumer.test.sh, selecting the existing test_outcomes_tool_uses_stock_execution_and_export_consumers function
- timeout -k 5s 200s python3 remote-fixture-drive.py, from this evidence directory

The Pi test executed the installed package's ToolExecutionComponent and HTML export consumer. The remote test used mocked SSH/Herdr and adapted only its disposable deployment: PATH Bash and ps replaced unavailable absolute paths, and the account home was redirected inside its fixture. Tracked product files were unchanged. The adapted remote fixture passed and cleaned its homes and owned processes. This supersedes the earlier README's remote-test omission. These automated checks are supporting evidence, not live fleet scenarios.

Fresh read-only GitHub requests confirm PR 5645's descriptive title, open/unmerged and mergeable state, existing branch and published head 23fa8f79. Compare proves the published head contains required base f5930603 with zero commits behind it. The force-push event records the original 9aa0e8a8 and rebased 23fa8f79 heads. GitHub cannot prove the publisher's force-with-lease command. Publication and attestation rebinding after this repair remain the outer executor's responsibility; this turn neither controlled a pipeline nor mutated GitHub.

The runtime change affects CLI output and persisted state. The Pi change adds tests only; no product UI changed, so no screenshot was captured. No full repository suite, linter, formatter or static analysis ran. All scratch material was removed and owned test process groups were verified stopped; dedicated evidence remains.
