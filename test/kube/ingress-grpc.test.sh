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

# run_nginx_case <name> <expected status> <backend-protocol>
run_nginx_case() {
    local name="$1" expected_status="$2"
    shift 2
    local status

    camunda_nginx_grpc_backend_protocol_valid "$@"
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

# --- ingress-nginx: the hint lives on the Ingress ------------------------------

run_nginx_case "nginx: backend-protocol GRPC is accepted" 0 "GRPC"
run_nginx_case "nginx: backend-protocol GRPCS is accepted (TLS upstream)" 0 "GRPCS"
run_nginx_case "nginx: an HTTP backend-protocol is not a gRPC hint" 1 "HTTPS"
run_nginx_case "nginx: no annotation at all is rejected" 1 ""

# --- Contour: the hint lives on the backing Service, and only for listed ports --

run_port_case "contour: a single matching port number is covered" \
    0 "26500" "26500" "gateway"

run_port_case "contour: a matching port name is covered" \
    0 "gateway" "26500" "gateway"

run_port_case "contour: one entry of a comma-separated list is covered" \
    0 "8080,26500,9090" "26500" "gateway"

run_port_case "contour: surrounding whitespace is tolerated" \
    0 "8080, 26500" "26500" "gateway"

# The annotation only switches the ports it lists, so an entry for a different
# backend port leaves the Zeebe upstream on HTTP/1.
run_port_case "contour: an unrelated port is not covered" \
    1 "8080" "26500" "gateway"

run_port_case "contour: a numeric prefix is not a match" \
    1 "2650" "26500" "gateway"

run_port_case "contour: an empty annotation covers nothing" \
    1 "" "26500" "gateway"

run_port_case "contour: a service without a named port still matches by number" \
    0 "26500" "26500" ""

# The Camunda Helm chart historically emitted
# nginx.ingress.kubernetes.io/backend-protocol whatever the ingress class
# (camunda/camunda-platform-helm#6410). The Contour predicate cannot read that
# annotation at all, so a leftover copy of it can never satisfy the check.
run_port_case "contour: an nginx backend-protocol value is not a port list" \
    1 "GRPC" "26500" "gateway"

if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%s: %s check(s) failed.\n' "$0" "$FAILURES" 1>&2
    exit 1
fi

printf '\n%s: all checks passed.\n' "$0"
