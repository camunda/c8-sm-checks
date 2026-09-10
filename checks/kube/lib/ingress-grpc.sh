# shellcheck shell=bash
#
# Resolution of the gRPC upstream hint an Ingress controller needs in order to
# proxy the Zeebe gateway.
#
# The hint is controller-specific, and the two supported controllers do not even
# carry it on the same object:
#
#   - ingress-nginx reads `nginx.ingress.kubernetes.io/backend-protocol` (GRPC,
#     or GRPCS when the upstream itself speaks TLS) from the Ingress.
#   - Contour reads `projectcontour.io/upstream-protocol.h2c` (plaintext HTTP/2)
#     or `.h2` (HTTP/2 over TLS) from the *Service* the Ingress routes to, so the
#     Ingress carries no gRPC annotation at all. The annotation value is a
#     comma-separated list of port names or numbers, and only the listed ports
#     get HTTP/2, so the routed port has to appear in it.
#     https://projectcontour.io/docs/1.33/config/annotations/
#
# Kept free of kubectl so it can be unit-tested without a cluster; the caller
# passes in the annotation values and the routed port it has already read.

# camunda_contour_upstream_protocol_covers_port <annotation-value> <port-number> <port-name>
#
# Returns 0 when the comma-separated annotation value selects the routed port,
# matching either its number or its name as Contour does.
camunda_contour_upstream_protocol_covers_port() {
    local annotation_value="$1"
    local port_number="$2"
    local port_name="$3"
    local entry

    [ -n "$annotation_value" ] || return 1

    local IFS=','
    for entry in $annotation_value; do
        entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
        [ -n "$entry" ] || continue
        if [ -n "$port_number" ] && [ "$entry" = "$port_number" ]; then
            return 0
        fi
        if [ -n "$port_name" ] && [ "$entry" = "$port_name" ]; then
            return 0
        fi
    done

    return 1
}

# camunda_ingress_grpc_hint_present <ingress-class> <nginx-backend-protocol> <contour-h2c> <contour-h2> <port-number> <port-name>
#
# Returns 0 when the given annotation values describe a working gRPC upstream
# for that ingress class, 1 otherwise. An unknown class always returns 1: the
# caller has no way to tell what such a controller would need.
camunda_ingress_grpc_hint_present() {
    local ingress_class="$1"
    local nginx_backend_protocol="$2"
    local contour_h2c="$3"
    local contour_h2="$4"
    local port_number="$5"
    local port_name="$6"

    case "$ingress_class" in
        nginx)
            [ "$nginx_backend_protocol" = "GRPC" ] || [ "$nginx_backend_protocol" = "GRPCS" ]
            ;;
        contour)
            # Deliberately ignores nginx.ingress.kubernetes.io/backend-protocol:
            # the Camunda chart emits it by default whatever the ingress class,
            # and Envoy does not read it (camunda/camunda-platform-helm#6410).
            camunda_contour_upstream_protocol_covers_port "$contour_h2c" "$port_number" "$port_name" ||
                camunda_contour_upstream_protocol_covers_port "$contour_h2" "$port_number" "$port_name"
            ;;
        *)
            return 1
            ;;
    esac
}
