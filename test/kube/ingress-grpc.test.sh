#!/bin/bash

# Unit tests for the gRPC upstream hint resolution
# (checks/kube/lib/ingress-grpc.sh).
#
# The hint that lets an Ingress controller proxy Zeebe's gRPC port is
# controller-specific, and the two controllers do not even carry it on the same
# object: ingress-nginx reads an annotation on the Ingress, Contour reads one on
# the Service the Ingress routes to. These tests pin that split, and in
# particular that a leftover nginx annotation does not satisfy Contour.
#
# Usage: ./test/kube/ingress-grpc.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/ingress-grpc.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/ingress-grpc.sh"

FAILURES=0

# run_case <name> <expected status> <ingress-class> <nginx-backend-protocol> <contour-h2c> <contour-h2>
run_case() {
    local name="$1" expected_status="$2"
    shift 2
    local status

    camunda_ingress_grpc_hint_present "$@"
    status=$?

    if [[ "$status" -eq "$expected_status" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- ingress-nginx: the hint lives on the Ingress ------------------------------

run_case "nginx: backend-protocol GRPC is accepted" \
    0 "nginx" "GRPC" "" ""

run_case "nginx: backend-protocol GRPCS is accepted (TLS upstream)" \
    0 "nginx" "GRPCS" "" ""

run_case "nginx: an HTTP backend-protocol is not a gRPC hint" \
    1 "nginx" "HTTPS" "" ""

run_case "nginx: no annotation at all is rejected" \
    1 "nginx" "" "" ""

# Contour's Service annotation means nothing to ingress-nginx, which only reads
# its own annotation off the Ingress.
run_case "nginx: a Contour upstream-protocol annotation does not satisfy nginx" \
    1 "nginx" "" "26500" ""

# --- Contour: the hint lives on the backing Service ----------------------------

run_case "contour: upstream-protocol.h2c is accepted (plaintext upstream)" \
    0 "contour" "" "26500" ""

run_case "contour: upstream-protocol.h2 is accepted (TLS upstream)" \
    0 "contour" "" "" "26500"

run_case "contour: a port name rather than a number is accepted" \
    0 "contour" "" "gateway" ""

run_case "contour: no upstream-protocol annotation is rejected" \
    1 "contour" "" "" ""

# The Camunda Helm chart still emits nginx.ingress.kubernetes.io/backend-protocol
# by default whatever the ingress class, so a Contour deployment carries it even
# though Envoy ignores it. It must not be mistaken for a working gRPC upstream.
# See camunda/camunda-platform-helm#6410.
run_case "contour: the chart's leftover nginx annotation does not satisfy Contour" \
    1 "contour" "GRPC" "" ""

# --- Other controllers ---------------------------------------------------------

run_case "an unknown ingress class has no known hint" \
    1 "traefik" "GRPC" "26500" ""

run_case "an empty ingress class has no known hint" \
    1 "" "" "" ""

if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%s: %s check(s) failed.\n' "$0" "$FAILURES" 1>&2
    exit 1
fi

printf '\n%s: all checks passed.\n' "$0"
