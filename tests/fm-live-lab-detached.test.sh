#!/usr/bin/env bash
FM_LIVE_LAB_TEST_GROUP=detached
export FM_LIVE_LAB_TEST_GROUP
# shellcheck source=tests/fm-live-lab.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-live-lab.test.sh"
