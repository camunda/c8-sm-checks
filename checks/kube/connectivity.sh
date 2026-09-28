#!/bin/bash

set -o pipefail

# Script to check the status of the deployment
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# shellcheck source=checks/kube/lib/ingress-grpc.sh
# shellcheck source-path=SCRIPTDIR
source "$DIR_NAME/lib/ingress-grpc.sh" || {
    echo 1>&2 "Error: unable to load $DIR_NAME/lib/ingress-grpc.sh. Run this script from a checkout of the repository so that checks/kube/lib/ is present. Aborting."
    exit 1
}

# shellcheck source=checks/kube/lib/exec-bound.sh
# shellcheck source-path=SCRIPTDIR
source "$DIR_NAME/lib/exec-bound.sh" || {
    echo 1>&2 "Error: unable to load $DIR_NAME/lib/exec-bound.sh. Run this script from a checkout of the repository so that checks/kube/lib/ is present. Aborting."
    exit 1
}

# Define default variables
NAMESPACE="${NAMESPACE:-""}"
# Wall-clock bound for a single `kubectl exec` probe. The probe itself is a TCP
# connect with a 2s in-container timeout, so anything approaching this value is
# a wedged exec stream rather than a slow service.
CAMUNDA_EXEC_TIMEOUT="${CAMUNDA_EXEC_TIMEOUT:-15}"
# Fail closed: the prefix is concatenated into commands run through `eval`, so a
# value that did not validate must stop the script rather than silently drop the
# bound or reach `eval` as-is.
EXEC_BOUND="$(camunda_exec_bound_prefix "$CAMUNDA_EXEC_TIMEOUT")" || exit 1
SKIP_CHECK_INGRESS_CLASS=0

usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use"
    echo "  -i                              Skip checks of the ingress class (default: $SKIP_CHECK_INGRESS_CLASS)"
    exit 1
}

# Parse command line options
while getopts ":hn:i" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
            ;;
        i)
            SKIP_CHECK_INGRESS_CLASS=1
            ;;
        \?)
            echo "Invalid option: $OPTARG" 1>&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." 1>&2
            usage
            ;;
    esac
done

SCRIPT_STATUS_OUTPUT=0

# Check if all required options are provided
if [ -z "$NAMESPACE" ]; then
    echo "Error: Missing one of the required options (list of all required options: NAMESPACE)." 1>&2
    usage
fi

# required commands
command -v kubectl >/dev/null 2>&1 || { echo >&2 "Error: kubectl is required but not installed. Please install it (https://kubernetes.io/docs/tasks/tools/). Aborting."; exit 1; }


# check if all services can be resolved in pods with in the pod
check_services_resolution() {
    echo "[INFO] Check services can be resolved in the pods"

    local pods
    local pods_command
    pods_command="kubectl get pods -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${pods_command}"
    pods=$(eval "${pods_command}")

    local services
    local services_command
    # we only take the first port as we only want to check service name resolution and nothing else
    # clusterIP comes first so headless services can be skipped below; it is emitted
    # first on purpose, see the right-to-left parsing in the loop
    services_command="kubectl get services -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.spec.clusterIP}:{.metadata.name}:{.spec.ports[0].port}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${services_command}"
    services=$(eval "${services_command}")

    # check service resolution for each pod
    for pod in $pods; do

        local check_method=""
        if eval "${EXEC_BOUND}kubectl exec -n \"$NAMESPACE\" \"$pod\" -- which bash" &>/dev/null; then
            check_method="bash"
        elif eval "${EXEC_BOUND}kubectl exec -n \"$NAMESPACE\" \"$pod\" -- which nc" &>/dev/null; then
            check_method="nc"
        else
            echo "Warning: Neither bash nor nc are available in pod $pod. Skipping service resolution check for this pod." >&2
            continue
        fi

        for service in $services; do
            # Parsed right to left: a service name and a port never contain a
            # colon, so whatever remains on the left is the cluster IP, colons
            # included. That keeps IPv6 and dual-stack clusters working, where
            # clusterIP looks like fd00:10:96::1.
            local service_port="${service##*:}"
            local service_rest="${service%:*}"
            local service_name="${service_rest##*:}"
            local service_cluster_ip="${service_rest%:*}"

            # Headless services (clusterIP None) publish the pod IPs of their
            # ready endpoints instead of a virtual IP, so their DNS name has no
            # A record at all while the backing workload has no ready pod. A
            # probe then fails with "Name or service not known", which reports a
            # rollout in progress rather than a connectivity problem. Every
            # workload that owns a headless service is also fronted by a regular
            # service, so skipping these loses no coverage.
            if [ "$service_cluster_ip" = "None" ]; then
                echo "[INFO] Skipping headless service $service_name:$service_port (no cluster IP; resolution depends on ready endpoints)"
                continue
            fi

            echo "[INFO] Checking service $service_name:$service_port from pod $pod"

            local check_output
            local check_command
            local check_status

            # depending of the available binaries in the container, we use various methods
            case $check_method in
                bash)
                    check_command="${EXEC_BOUND}kubectl exec -n \"$NAMESPACE\" \"$pod\" -- timeout 2 bash -c '</dev/tcp/$service_name/$service_port'"
                    ;;
                nc)
                    check_command="${EXEC_BOUND}kubectl exec -n \"$NAMESPACE\" \"$pod\" -- nc -zv \"$service_name\" \"$service_port\""
                    ;;
                *)
                    echo "Error: Unsupported check method \"$check_method\"" >&2
                    exit 1
                    ;;
            esac

            # we use sh to ensure compatibility with most of the container images https://stackoverflow.com/a/14701003
            echo "[INFO] Running command: ${check_command}"
            check_output=$(eval "${check_command}" 2>&1)
            check_status=$?

            # A killed exec produces no output, and the output-based verdict
            # below would read that emptiness as success. Classify it first.
            if camunda_exec_timed_out "$check_status"; then
                echo "[FAIL] Service $service_name:$service_port probe from pod $pod in namespace $NAMESPACE timed out after ${CAMUNDA_EXEC_TIMEOUT}s: the exec stream never returned" >&2
                SCRIPT_STATUS_OUTPUT=2
                continue
            fi

            # We prefer to check the output rather than the exit code as we care about service name resolution, not the flow opening
            # "Invalid argument" is the error of the bash check
            # "bad address" is the error of the nc check
            if ! echo "$check_output" | grep -q -e "bad address" -e "Invalid argument"; then
                echo "[OK] Service $service_name:$service_port resolved successfully from pod $pod in namespace $NAMESPACE"
            else
                echo "[FAIL] Service $service_name:$service_port resolution failed from pod $pod in namespace $NAMESPACE: $check_output" >&2
                SCRIPT_STATUS_OUTPUT=2
            fi
        done
    done
}
check_services_resolution

# Value of a single annotation; the key arrives with its dots already escaped for jsonpath.
ingress_annotation() {
    kubectl get ingress -n "$NAMESPACE" "$1" -o jsonpath="{.metadata.annotations.$2}" 2>/dev/null
}

service_annotation() {
    kubectl get service -n "$NAMESPACE" "$1" -o jsonpath="{.metadata.annotations.$2}" 2>/dev/null
}

# "<service>|<port-number>|<port-name>" per backend the Ingress routes to, default
# backend included: Contour takes its upstream protocol from the backend Service,
# not from the Ingress, and only for the ports the annotation lists. Pipe-separated
# because a port reference carries either a number or a name, never both, and a
# whitespace separator would collapse the empty field and shift the other one.
ingress_backends() {
    kubectl get ingress -n "$NAMESPACE" "$1" -o jsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{"|"}{.backend.service.port.number}{"|"}{.backend.service.port.name}{"\n"}{end}{.spec.defaultBackend.service.name}{"|"}{.spec.defaultBackend.service.port.number}{"|"}{.spec.defaultBackend.service.port.name}{"\n"}' 2>/dev/null | grep -v '^||$'
}

# An Ingress may reference a Service port by number or by name, while Contour's
# annotation may list either. Resolve the missing half so both can be matched.
service_port_pair() {
    local service_name="$1"
    local port_number="$2"
    local port_name="$3"

    if [ -n "$port_number" ] && [ -n "$port_name" ]; then
        printf '%s|%s' "$port_number" "$port_name"
        return
    fi
    if [ -n "$port_number" ]; then
        printf '%s|%s' "$port_number" \
            "$(kubectl get service -n "$NAMESPACE" "$service_name" -o jsonpath="{.spec.ports[?(@.port==$port_number)].name}" 2>/dev/null)"
        return
    fi
    printf '%s|%s' \
        "$(kubectl get service -n "$NAMESPACE" "$service_name" -o jsonpath="{.spec.ports[?(@.name=='$port_name')].port}" 2>/dev/null)" \
        "$port_name"
}

ingress_declares_grpc_upstream() {
    local ingress_name="$1"
    local ingress_class="$2"
    local service_name port_number port_name

    case "$ingress_class" in
        nginx)
            camunda_nginx_grpc_backend_protocol_valid \
                "$(ingress_annotation "$ingress_name" 'nginx\.ingress\.kubernetes\.io/backend-protocol')"
            return
            ;;
        contour) ;;
        *) return 1 ;;
    esac

    while IFS="|" read -r service_name port_number port_name; do
        [ -n "$service_name" ] || continue
        IFS="|" read -r port_number port_name <<<"$(service_port_pair "$service_name" "$port_number" "$port_name")"
        if camunda_contour_upstream_protocol_covers_port \
            "$(service_annotation "$service_name" 'projectcontour\.io/upstream-protocol\.h2c')" \
            "$port_number" "$port_name" ||
            camunda_contour_upstream_protocol_covers_port \
                "$(service_annotation "$service_name" 'projectcontour\.io/upstream-protocol\.h2')" \
                "$port_number" "$port_name"; then
            return 0
        fi
    done <<EOF
$(ingress_backends "$ingress_name")
EOF

    return 1
}

check_ingress_class_and_config() {
    echo "[INFO] Check ingress and associated configuration"

    local annotation_found
    annotation_found=0

    local ingress_list
    local ingress_list_command
    ingress_list_command="kubectl get ingress -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${ingress_list_command}"
    ingress_list=$(eval "${ingress_list_command}")

    # check each ingress listed
    for ingress_name in $ingress_list; do
        local ingress_class
        local ingress_class_command
        ingress_class_command="kubectl get ingress -n \"$NAMESPACE\" \"$ingress_name\" -o jsonpath='{.spec.ingressClassName}'"
        echo "[INFO] Running command: ${ingress_class_command}"
        ingress_class=$(eval "${ingress_class_command}")

        if [ "$ingress_class" != "nginx" ] && [ "$ingress_class" != "contour" ]; then
            echo "[FAIL] Ingress class is not nginx or contour for $ingress_name. Actual class: $ingress_class." >&2
            echo "If you configured it on purpose, please use the SKIP_CHECK_INGRESS_CLASS option." >&2
            SCRIPT_STATUS_OUTPUT=3
        else
            echo "[OK] Ingress class for $ingress_name is configured correctly with $ingress_class."
        fi

        if ingress_declares_grpc_upstream "$ingress_name" "$ingress_class"; then
            echo "[OK] Ingress $ingress_name declares a gRPC upstream for the $ingress_class controller."
            annotation_found=1
        fi
    done

    if [ "$annotation_found" -eq 0 ]; then
        echo "[FAIL] None of the ingresses declare a gRPC upstream, which is required for the zeebe ingress." >&2
        echo "With ingress-nginx, the zeebe ingress must carry nginx.ingress.kubernetes.io/backend-protocol: GRPC (GRPCS for a TLS upstream)." >&2
        echo "With Contour, the service behind it must carry projectcontour.io/upstream-protocol.h2c (.h2 for a TLS upstream) listing the gRPC port." >&2
        SCRIPT_STATUS_OUTPUT=5
    fi
}
if [ "$SKIP_CHECK_INGRESS_CLASS" -eq 0 ]; then
    check_ingress_class_and_config
fi

# Check if SCRIPT_STATUS_OUTPUT is not equal to zero
if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[FAIL] ${LVL_1_SCRIPT_NAME}: At least one of the tests failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All test passed."
fi
