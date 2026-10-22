# shellcheck shell=bash
#
# Which Services the connectivity sweep should probe.
#
# The sweep checks service name resolution by opening a TCP connection to every
# Service from every pod. Two kinds of Service cannot give a meaningful answer to
# that probe, and are skipped:
#
# - headless Services (clusterIP None) publish the pod IPs of their ready
#   endpoints instead of a virtual IP, so their name does not resolve at all
#   while the backing workload has no ready pod;
# - ClusterIP Services with no ready endpoints resolve, but the virtual IP has
#   nothing behind it, so the connect is either refused or left unanswered
#   depending on kernel retransmit timing. The outcome says nothing about name
#   resolution and flips between runs.
#
# Kept free of kubectl so it can be unit-tested without a cluster; the caller
# lists the EndpointSlices once per sweep and passes the result in.

# jsonpath for `kubectl get endpointslices`, emitting one line per slice shaped
# as <service-name>|<ready>,<ready>,..., for camunda_services_with_ready_endpoints.
# shellcheck disable=SC2034 # used by checks/kube/connectivity.sh
CAMUNDA_ENDPOINTSLICE_READY_JSONPATH='{range .items[*]}{.metadata.labels.kubernetes\.io/service-name}{"|"}{range .endpoints[*]}{.conditions.ready}{","}{end}{"\n"}{end}'

# camunda_services_with_ready_endpoints
#
# Reads the output of CAMUNDA_ENDPOINTSLICE_READY_JSONPATH on stdin and echoes,
# one per line, the names of the Services with at least one ready endpoint. A
# Service may be split across several slices, so readiness is aggregated per
# name. Slices without the service-name label are ignored.
#
# An endpoint whose ready condition is unset emits an empty field. The
# EndpointSlice API documents that unknown state as one consumers should treat
# as ready, and treating it so errs towards probing rather than skipping.
camunda_services_with_ready_endpoints() {
    awk -F'|' '
        $1 == "" || seen[$1] { next }
        {
            n = split($2, ready, ",")
            # Every endpoint is followed by a comma, so the last field is the
            # empty remainder after it, not an endpoint.
            for (i = 1; i < n; i++) {
                if (ready[i] == "true" || ready[i] == "") {
                    print $1
                    seen[$1] = 1
                    break
                }
            }
        }
    '
}

# camunda_service_is_headless <cluster-ip>
#
# Returns 0 when the Service is headless.
camunda_service_is_headless() {
    [ "$1" = "None" ]
}

# camunda_service_lacks_ready_endpoints <cluster-ip> <service-name> <ready-services>
#
# Returns 0 when the Service has a virtual IP but no ready endpoint behind it,
# i.e. its name is absent from <ready-services>, the newline-separated output of
# camunda_services_with_ready_endpoints. Services without a virtual IP are left
# alone: headless ones have their own skip, and ExternalName ones (no cluster
# IP) resolve to a name outside the cluster that has no EndpointSlice at all.
camunda_service_lacks_ready_endpoints() {
    local cluster_ip="$1" service_name="$2" ready_services="$3"

    if [ -z "$cluster_ip" ] || camunda_service_is_headless "$cluster_ip"; then
        return 1
    fi

    # Whole-line match, so a name that is a prefix of a ready one is not
    # mistaken for it.
    case $'\n'"$ready_services"$'\n' in
        *$'\n'"$service_name"$'\n'*) return 1 ;;
    esac
    return 0
}
