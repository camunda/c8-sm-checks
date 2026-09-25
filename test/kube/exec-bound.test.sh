#!/bin/bash

# Unit tests for the client-side exec bound (checks/kube/lib/exec-bound.sh).
#
# The connectivity sweep probes Services with `kubectl exec <pod> -- timeout 2
# bash -c '</dev/tcp/host/port'`. That inner timeout runs in the container and
# bounds the probe, not the exec. These tests pin the two things the sweep needs
# from the bound: that a prefix is produced when a timeout binary exists and
# omitted when none does, and that the status coreutils reports after killing a
# command is recognised -- because a killed exec emits nothing, and the sweep's
# output-based verdict would otherwise read that silence as success.
#
# Usage: ./test/kube/exec-bound.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/exec-bound.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/exec-bound.sh"

FAILURES=0

# run_prefix_case <name> <expected prefix> <seconds> [binary]
run_prefix_case() {
    local name="$1" expected="$2"
    shift 2
    local actual

    actual="$(camunda_exec_bound_prefix "$@")"

    if [[ "$actual" == "$expected" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected %q, got %q\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# run_status_case <name> <expected status> <input status>
run_status_case() {
    local name="$1" expected_status="$2" input="$3"
    local status

    camunda_exec_timed_out "$input"
    status=$?

    if [[ "$status" -eq "$expected_status" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status"
        FAILURES=$((FAILURES + 1))
    fi
}

# The prefix is concatenated straight onto a command string, so the trailing
# space is part of the contract.
run_prefix_case "GNU timeout is used verbatim, with a trailing space" \
    'timeout 15 ' 15 timeout
run_prefix_case "the Homebrew coreutils name is honoured" \
    'gtimeout 15 ' 15 gtimeout
run_prefix_case "a different bound is carried through" \
    'timeout 5 ' 5 timeout

# A host with no coreutils still has to run the checks; it just loses the bound.
# An empty prefix leaves the original command untouched.
PATH='' run_prefix_case "no timeout binary yields no prefix" '' 15

# The prefix is concatenated into a string the caller runs through `eval`, and
# the duration reaches it from the environment. An unvalidated value is both a
# silent-failure source -- `timeout` rejects a bad interval with status 125 and
# a message matching none of the caller's error patterns, which reads as
# success -- and an injection vector. Fail closed on both.
run_reject_case() {
    local name="$1" value="$2"
    local output status

    output="$(camunda_exec_bound_prefix "$value" timeout 2>/dev/null)"
    status=$?

    if [[ "$status" -ne 0 && -z "$output" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected a non-zero status and no prefix, got status %s and %q\n' \
            "$name" "$status" "$output"
        FAILURES=$((FAILURES + 1))
    fi
}

run_reject_case "a non-numeric duration is rejected" "abc"
run_reject_case "an empty duration is rejected" ""
run_reject_case "a shell metacharacter is rejected" "5;rm -rf /"
run_reject_case "an appended command is rejected" "5 echo INJECTED;"
run_reject_case "a negative duration is rejected" "-5"
run_reject_case "a suffix in the middle is rejected" "5s5"

# coreutils accepts a unit suffix, and so do we.
run_prefix_case "a seconds suffix is accepted" 'timeout 30s ' 30s timeout
run_prefix_case "a minutes suffix is accepted" 'timeout 2m ' 2m timeout

# 124 is what coreutils timeout reports after killing the command. Anything
# else is the command's own status and must not be mistaken for a timeout.
run_status_case "124 is recognised as a timeout" 0 124
run_status_case "success is not a timeout" 1 0
run_status_case "a failed probe is not a timeout" 1 1
run_status_case "SIGKILL of the command itself is not a timeout" 1 137

if [[ "$FAILURES" -gt 0 ]]; then
    printf '\n%s test(s) failed\n' "$FAILURES"
    exit 1
fi

printf '\nAll tests passed\n'
