#!/bin/bash

# Unit tests for the Keycloak deployment-mode resolution
# (checks/kube/lib/keycloak-mode.sh).
#
# They pin the behaviour that camunda/c8-sm-checks#352 got wrong: the decision
# has to follow the identityKeycloak subchart, not
# `global.identity.keycloak.internal`, and a boolean false must survive the
# read.
#
# Usage: ./test/kube/keycloak-mode.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/keycloak-mode.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/keycloak-mode.sh"

command -v jq >/dev/null 2>&1 || { echo 1>&2 "Error: jq is required but not installed. Aborting."; exit 1; }

FAILURES=0

# assert_equals <name> <expected> <actual>
assert_equals() {
    if [[ "$3" == "$2" ]]; then
        printf '[OK] %s\n' "$1"
    else
        printf '[FAIL] %s: expected "%s", got "%s"\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

# Chart defaults up to 8.9: the subchart exists and ships disabled, and the
# unrelated ExternalName flag defaults to false.
DEFAULTS_8_9='{"identityKeycloak":{"enabled":false},"global":{"identity":{"keycloak":{"internal":false}}}}'

# Chart 8.10 defaults: identityKeycloak is gone, internal still defaults to
# false.
DEFAULTS_8_10='{"global":{"identity":{"keycloak":{"internal":false}}}}'

assert_equals "8.9 bundled Keycloak is reported as deployed" \
    "true" \
    "$(camunda_keycloak_subchart_enabled '{"identityKeycloak":{"enabled":true}}' "$DEFAULTS_8_9")"

assert_equals "8.9 external Keycloak is reported as not deployed" \
    "false" \
    "$(camunda_keycloak_subchart_enabled '{"identityKeycloak":{"enabled":false}}' "$DEFAULTS_8_9")"

assert_equals "8.9 chart default applies when the release overrides nothing" \
    "false" \
    "$(camunda_keycloak_subchart_enabled '{}' "$DEFAULTS_8_9")"

assert_equals "8.10 missing identityKeycloak key means not deployed" \
    "false" \
    "$(camunda_keycloak_subchart_enabled '{}' "$DEFAULTS_8_10")"

# The regression the previous implementation shipped: it read
# global.identity.keycloak.internal through `//`, which discards a boolean
# false, so it never reached its own operator-managed branch.
assert_equals "an explicit internal:false does not flip the answer" \
    "true" \
    "$(camunda_keycloak_subchart_enabled \
        '{"identityKeycloak":{"enabled":true},"global":{"identity":{"keycloak":{"internal":false}}}}' \
        "$DEFAULTS_8_9")"

assert_equals "an explicit internal:true does not flip the answer either" \
    "false" \
    "$(camunda_keycloak_subchart_enabled \
        '{"global":{"identity":{"keycloak":{"internal":true}}}}' \
        "$DEFAULTS_8_10")"

if [[ "$FAILURES" -gt 0 ]]; then
    printf '\n%s test(s) failed.\n' "$FAILURES"
    exit 1
fi

printf '\nAll tests passed.\n'
