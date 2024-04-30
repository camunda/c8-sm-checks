#!/bin/bash

set -o pipefail

# Script to check the status of the deployment
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Define default variables
NAMESPACE=""
SKIP_CHECK_INGRESS_CLASS=0

usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-d HELM_DEPLOYMENT_NAME]"
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


# check if all services can be resolved in pods with curl in the pod
check_services_resolution() {
    echo "[INFO] Check services can be resolved in the pods"

    local pods
    local pods_command
    pods_command="kubectl get pods -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${pods_command}"
    pods=$(eval "${pods_command}")

    local services
    local services_command
    services_command="kubectl get services -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${services_command}"
    services=$(eval "${services_command}")

    # for each pod, we check if all the services can be resolved
    for pod in $pods; do

        if ! kubectl exec -n "$NAMESPACE" "$pod" -- curl --version &>/dev/null; then
            echo "Warning: curl is not available in pod $pod. Skipping service resolution check for this pod." >&2
            continue
        fi

        for service in $services; do
            local curl_output
            local curl_command
            curl_command="kubectl exec -n \"$NAMESPACE\" \"$pod\" -- curl -s -v --max-time 1 \"$service\""
            echo "[INFO] Running command: ${curl_command}"
            curl_output=$(eval "${curl_command}" 2>&1)

            # Check if the output contains "Trying ip:port" (IPv4 or IPv6)
            if echo "$curl_output" | grep -Eq "Trying ([0-9.]*|\[[0-9a-fA-F:]*\]):[0-9]*"; then
                echo "[OK] Service $service resolved successfully from pod $pod in namespace $NAMESPACE"
            else
                echo "[FAIL] Service $service resolution failed from pod $pod in namespace $NAMESPACE: $curl_output" >&2
                SCRIPT_STATUS_OUTPUT=2
            fi
        done
    done
}
check_services_resolution

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

        if [ "$ingress_class" != "nginx" ]; then
            echo "[FAIL] Ingress class is not nginx for $ingress_name. Actual class: $ingress_class." >&2
            echo "If you configured it on purpose, please the SKIP_CHECK_INGRESS_CLASS option." >&2
            SCRIPT_STATUS_OUTPUT=3
        else
            echo "[OK] Ingress class for $ingress_name is configured correctly with $ingress_class."
        fi

        if kubectl get ingress -n "$NAMESPACE" "$ingress_name" -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/backend-protocol}' | grep -q "GRPC"; then
            annotation_found=1
        fi
    done

    if [ "$annotation_found" -eq 0 ]; then
        echo "[FAIL] None of the ingresses contain the annotation nginx.ingress.kubernetes.io/backend-protocol: GRPC, which is required for zeebe ingress." >&2
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
