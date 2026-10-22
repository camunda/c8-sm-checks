#!/bin/bash

# Unit tests for the connectivity sweep's service skips
# (checks/kube/lib/service-endpoints.sh).
#
# The lib header explains why these Services cannot be probed. These tests pin
# which ones are skipped and how the ready set is built from the EndpointSlices.
#
# Usage: ./test/kube/service-endpoints.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/service-endpoints.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/service-endpoints.sh"

FAILURES=0

# run_ready_set_case <name> <expected set> <endpointslices jsonpath output>
run_ready_set_case() {
    local name="$1" expected="$2" input="$3"
    local actual

    actual="$(printf '%s' "$input" | camunda_services_with_ready_endpoints)"

    if [[ "$actual" == "$expected" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected %q, got %q\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# run_skip_case <name> <expected status> <predicate> <args...>
run_skip_case() {
    local name="$1" expected_status="$2"
    shift 2
    local status

    "$@"
    status=$?

    if [[ "$status" -eq "$expected_status" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status"
        FAILURES=$((FAILURES + 1))
    fi
}

# Building the ready set. Each line is one EndpointSlice, shaped
# <service-name>|<ready>,<ready>,..., as the sweep's jsonpath emits it.
run_ready_set_case "a slice with a ready endpoint marks its service ready" \
    'camunda-zeebe-gateway' $'camunda-zeebe-gateway|true,\n'
run_ready_set_case "a slice whose endpoints are all unready marks nothing" \
    '' $'camunda-zeebe-gateway|false,false,\n'
run_ready_set_case "a slice with no endpoints marks nothing" \
    '' $'camunda-zeebe-gateway|\n'
run_ready_set_case "one ready endpoint among unready ones is enough" \
    'camunda-zeebe-gateway' $'camunda-zeebe-gateway|false,true,false,\n'
# A Service may be split across several slices; readiness is per Service.
run_ready_set_case "readiness is aggregated across the slices of a service" \
    'camunda-zeebe-gateway' $'camunda-zeebe-gateway|false,\ncamunda-zeebe-gateway|true,\n'
run_ready_set_case "a service ready in several slices is listed once" \
    'camunda-zeebe-gateway' $'camunda-zeebe-gateway|true,\ncamunda-zeebe-gateway|true,\n'
# The API documents an unset ready condition as unknown, to be treated as ready.
run_ready_set_case "an unset ready condition counts as ready" \
    'camunda-zeebe-gateway' $'camunda-zeebe-gateway|,\n'
run_ready_set_case "a slice without the service-name label is ignored" \
    '' $'|true,\n'
run_ready_set_case "services are kept apart" \
    $'camunda-zeebe-gateway\ncamunda-identity' \
    $'camunda-zeebe-gateway|true,\ncamunda-optimize|false,\ncamunda-identity|true,\ncamunda-connectors|\n'
run_ready_set_case "no slices at all yields an empty set" \
    '' ''

# Headless services (#337).
run_skip_case "a headless service is skipped" 0 \
    camunda_service_is_headless None
run_skip_case "an IPv4 cluster IP is not headless" 1 \
    camunda_service_is_headless 10.96.0.10
run_skip_case "an IPv6 cluster IP is not headless" 1 \
    camunda_service_is_headless fd00:10:96::1
run_skip_case "an empty cluster IP (ExternalName) is not headless" 1 \
    camunda_service_is_headless ''

READY=$'camunda-identity\ncamunda-zeebe-gateway'

# ClusterIP services with no ready endpoints.
run_skip_case "a ClusterIP service with no ready endpoints is skipped" 0 \
    camunda_service_lacks_ready_endpoints 10.96.0.10 camunda-optimize "$READY"
run_skip_case "an IPv6 ClusterIP service with no ready endpoints is skipped" 0 \
    camunda_service_lacks_ready_endpoints fd00:10:96::1 camunda-optimize "$READY"
run_skip_case "a ClusterIP service with ready endpoints is probed" 1 \
    camunda_service_lacks_ready_endpoints 10.96.0.10 camunda-zeebe-gateway "$READY"
run_skip_case "the first service of the ready set is probed" 1 \
    camunda_service_lacks_ready_endpoints 10.96.0.10 camunda-identity "$READY"
run_skip_case "a prefix of a ready service name is not mistaken for it" 0 \
    camunda_service_lacks_ready_endpoints 10.96.0.10 camunda-zeebe "$READY"
run_skip_case "a ClusterIP service is skipped when no service is ready" 0 \
    camunda_service_lacks_ready_endpoints 10.96.0.10 camunda-zeebe-gateway ''
# Left to the headless skip, which reports why it skipped.
run_skip_case "a headless service is not reported as lacking endpoints" 1 \
    camunda_service_lacks_ready_endpoints None camunda-zeebe "$READY"
# ExternalName services have no cluster IP and no EndpointSlice; they still
# resolve, to a name outside the cluster, and are probed as before.
run_skip_case "an ExternalName service is not reported as lacking endpoints" 1 \
    camunda_service_lacks_ready_endpoints '' external-db "$READY"

if [[ "$FAILURES" -gt 0 ]]; then
    printf '\n%s test(s) failed\n' "$FAILURES"
    exit 1
fi

printf '\nAll tests passed\n'
