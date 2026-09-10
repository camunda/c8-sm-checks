#!/bin/bash

# Unit tests for the gRPC upstream hint resolution
# (checks/kube/lib/ingress-grpc.sh).
#
# The hint that lets an Ingress controller proxy Zeebe's gRPC port is
# controller-specific, and the two controllers do not even carry it on the same
# object: ingress-nginx reads an annotation on the Ingress, Contour reads one on
# the Service the Ingress routes to, and only for the ports that annotation
# lists. These tests pin that split, that a leftover nginx annotation does not
# satisfy Contour, and that an annotation for an unrelated port does not either.
#
# Usage: ./test/kube/ingress-grpc.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/ingress-grpc.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/ingress-grpc.sh"

FAILURES=0

# run_case <name> <expected status> <ingress-class> <nginx-backend-protocol> <contour-h2c> <contour-h2> <port-number> <port-name>
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

# run_port_case <name> <expected status> <annotation-value> <port-number> <port-name>
run_port_case() {
    local name="$1" expected_status="$2"
    shift 2
    local status

    camunda_contour_upstream_protocol_covers_port "$@"
    status=$?

    if [[ "$status" -eq "$expected_status" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- Contour port selection ----------------------------------------------------

run_port_case "port: a single matching number is covered" \
    0 "26500" "26500" "gateway"

run_port_case "port: a matching name is covered" \
    0 "gateway" "26500" "gateway"

run_port_case "port: one entry of a comma-separated list is covered" \
    0 "8080,26500,9090" "26500" "gateway"

run_port_case "port: surrounding whitespace is tolerated" \
    0 "8080, 26500" "26500" "gateway"

run_port_case "port: an unrelated port is not covered" \
    1 "8080" "26500" "gateway"

run_port_case "port: a numeric prefix is not a match" \
    1 "2650" "26500" "gateway"

run_port_case "port: an empty annotation covers nothing" \
    1 "" "26500" "gateway"

run_port_case "port: a service without a named port still matches by number" \
    0 "26500" "26500" ""

# --- ingress-nginx: the hint lives on the Ingress ------------------------------

run_case "nginx: backend-protocol GRPC is accepted" \
    0 "nginx" "GRPC" "" "" "" ""

run_case "nginx: backend-protocol GRPCS is accepted (TLS upstream)" \
    0 "nginx" "GRPCS" "" "" "" ""

run_case "nginx: an HTTP backend-protocol is not a gRPC hint" \
    1 "nginx" "HTTPS" "" "" "" ""

run_case "nginx: no annotation at all is rejected" \
    1 "nginx" "" "" "" "" ""

# Contour's Service annotation means nothing to ingress-nginx, which only reads
# its own annotation off the Ingress.
run_case "nginx: a Contour upstream-protocol annotation does not satisfy nginx" \
    1 "nginx" "" "26500" "" "26500" "gateway"

# --- Contour: the hint lives on the backing Service ----------------------------

run_case "contour: upstream-protocol.h2c covering the port is accepted" \
    0 "contour" "" "26500" "" "26500" "gateway"

run_case "contour: upstream-protocol.h2 covering the port is accepted (TLS upstream)" \
    0 "contour" "" "" "26500" "26500" "gateway"

run_case "contour: a port name rather than a number is accepted" \
    0 "contour" "" "gateway" "" "26500" "gateway"

run_case "contour: no upstream-protocol annotation is rejected" \
    1 "contour" "" "" "" "26500" "gateway"

# The annotation only switches the ports it lists, so an entry for a different
# backend port leaves the Zeebe upstream on HTTP/1.
run_case "contour: an annotation for an unrelated port does not satisfy the check" \
    1 "contour" "" "8080" "" "26500" "gateway"

# The Camunda Helm chart still emits nginx.ingress.kubernetes.io/backend-protocol
# by default whatever the ingress class, so a Contour deployment carries it even
# though Envoy ignores it. It must not be mistaken for a working gRPC upstream.
# See camunda/camunda-platform-helm#6410.
run_case "contour: the chart's leftover nginx annotation does not satisfy Contour" \
    1 "contour" "GRPC" "" "" "26500" "gateway"

# --- Other controllers ---------------------------------------------------------

run_case "an unknown ingress class has no known hint" \
    1 "traefik" "GRPC" "26500" "" "26500" "gateway"

run_case "an empty ingress class has no known hint" \
    1 "" "" "" "" "" ""

if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%s: %s check(s) failed.\n' "$0" "$FAILURES" 1>&2
    exit 1
fi

printf '\n%s: all checks passed.\n' "$0"
