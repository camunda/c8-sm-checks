#!/bin/bash

set -o pipefail

# Script to check the status of the deployment
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Define default variables
NAMESPACE="${NAMESPACE:-""}"
HELM_DEPLOYMENT_NAME="${HELM_DEPLOYMENT_NAME:-"camunda"}"
SKIP_CHECK_HELM_DEPLOYMENT=0

DEFAULT_REQUIRED_CONTAINERS="connector,optimize,zeebe"
REQUIRED_CONTAINERS=()
IFS=',' read -ra REQUIRED_CONTAINERS <<< "$DEFAULT_REQUIRED_CONTAINERS"

CHECK_CONSOLE_HUB_FEATURE=0
CONSOLE_HUB_CONTAINER="web-modeler-restapi"
CONSOLE_HUB_ENV="CAMUNDA_MODELER_FEATURE_CONSOLE_ENABLED"

usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-d HELM_DEPLOYMENT_NAME]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use"
    echo "  -d HELM_DEPLOYMENT_NAME         Specify the name of the helm deployment (default: $HELM_DEPLOYMENT_NAME)"
    echo "  -l                              Skip checks of the helm deployment (default: $SKIP_CHECK_HELM_DEPLOYMENT)"
    echo "  -c                              Specify the list of containers to check (comma-separated, default: ${DEFAULT_REQUIRED_CONTAINERS})"
    echo "  -o                              Check that Console is enabled as a Camunda Hub feature on the ${CONSOLE_HUB_CONTAINER} container instead of expecting a standalone console container (Camunda 8.10+)"
    exit 1
}

# Parse command line options
while getopts ":hd:n:c:lo" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
            ;;
        d)
            HELM_DEPLOYMENT_NAME=$OPTARG
            ;;
        l)
            SKIP_CHECK_HELM_DEPLOYMENT=1
            ;;
        c)
            IFS=',' read -ra REQUIRED_CONTAINERS <<< "$OPTARG"
            ;;
        o)
            CHECK_CONSOLE_HUB_FEATURE=1
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


# Helm checks of the deployment
check_helm_deployment() {
    echo "[INFO] Check status of the last helm deployment"

    local last_deployment
    local last_deployment_command
    last_deployment_command="helm list -n \"$NAMESPACE\" | grep \"$HELM_DEPLOYMENT_NAME\" | head -n 1"
    echo "[INFO] Running command: ${last_deployment_command}"
    last_deployment=$(eval "${last_deployment_command}")

    if [[ -n "$last_deployment" ]]; then
        deployment_status=$(echo "$last_deployment" | awk '{ print $8 }')
        if [[ "$deployment_status" == "deployed" ]]; then
            echo "[OK] Last Helm deployment $HELM_DEPLOYMENT_NAME was successful"
        else
            echo "[FAIL] Last Helm deployment $HELM_DEPLOYMENT_NAME was not successful: (status=$deployment_status)" >&2
            SCRIPT_STATUS_OUTPUT=2
        fi
    else
        echo "[FAIL] No deployment found for $HELM_DEPLOYMENT_NAME in namespace $NAMESPACE" >&2
        SCRIPT_STATUS_OUTPUT=3
    fi
}
if [ "$SKIP_CHECK_HELM_DEPLOYMENT" -eq 0 ]; then
    command -v helm >/dev/null 2>&1 || { echo >&2 "Error: helm is required but not installed. Please install it (https://helm.sh/docs/intro/install/). Aborting."; exit 1; }
    check_helm_deployment
fi

# check if any pod is in an unhealthy state in the namespace
check_unhealthy_pods() {
    echo "[INFO] Check absenced of unhealthy containers"

    local unhealthy_pods
    local unhealthy_pods_command
    unhealthy_pods_command="kubectl get pods -n \"$NAMESPACE\" --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers"
    echo "[INFO] Running command: ${unhealthy_pods_command}"
    unhealthy_pods=$(eval "${unhealthy_pods_command}")

    if [[ -z "$unhealthy_pods" ]]; then
        echo "[OK] All pods are in an healthy state in namespace $NAMESPACE"
    else
        echo "[FAIL] Pods in unhealthy state in namespace $NAMESPACE:" >&2
        echo "$unhealthy_pods" >&2
        SCRIPT_STATUS_OUTPUT=4
    fi
}
check_unhealthy_pods

# check if required containers exist in the pods in the namespace
check_containers_in_pods() {
    local required_containers
    required_containers=("${REQUIRED_CONTAINERS[@]}")
    echo "[INFO] Check presence of required containers ${required_containers[*]}"

    local pods_containers
    local pods_containers_command
    pods_containers_command="kubectl get pods -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.spec.containers[*].name}{\"\n\"}{end}'"
    echo "[INFO] Running command: ${pods_containers_command}"
    pods_containers=$(eval "${pods_containers_command}")

    for container in "${required_containers[@]}"; do
        # Check if the container exists in any pod
        if ! echo "$pods_containers" | awk -v container="$container" '$0 ~ container { found = 1; exit } END { exit !found }'; then
            echo "[FAIL] The following required container is missing in the pods in namespace $NAMESPACE: $container" >&2
            SCRIPT_STATUS_OUTPUT=5
        fi
    done
}
check_containers_in_pods

# From Camunda 8.10 Console has no standalone deployment: it is a Web Modeler
# feature toggled by CAMUNDA_MODELER_FEATURE_CONSOLE_ENABLED, so it cannot be
# asserted by container name.
check_console_hub_feature() {
    if [[ "$CHECK_CONSOLE_HUB_FEATURE" -ne 1 ]]; then
        return
    fi

    echo "[INFO] Check presence of Console as a Camunda Hub feature on ${CONSOLE_HUB_CONTAINER}"

    local console_enabled
    local console_enabled_command
    console_enabled_command="kubectl get pods -n \"$NAMESPACE\" -o jsonpath='{range .items[*]}{range .spec.containers[?(@.name==\"${CONSOLE_HUB_CONTAINER}\")]}{range .env[?(@.name==\"${CONSOLE_HUB_ENV}\")]}{.value}{\"\n\"}{end}{end}{end}'"
    echo "[INFO] Running command: ${console_enabled_command}"
    console_enabled=$(eval "${console_enabled_command}" | grep -v '^$' | head -n 1)

    if [[ "$console_enabled" == "true" ]]; then
        echo "[OK] Console is enabled as a Camunda Hub feature on ${CONSOLE_HUB_CONTAINER} in namespace $NAMESPACE"
    elif [[ -z "$console_enabled" ]]; then
        echo "[FAIL] ${CONSOLE_HUB_ENV} is not set on any ${CONSOLE_HUB_CONTAINER} container in namespace $NAMESPACE" >&2
        SCRIPT_STATUS_OUTPUT=6
    else
        echo "[FAIL] Console is not enabled as a Camunda Hub feature in namespace $NAMESPACE (${CONSOLE_HUB_ENV}=${console_enabled})" >&2
        SCRIPT_STATUS_OUTPUT=6
    fi
}
check_console_hub_feature

# Check if SCRIPT_STATUS_OUTPUT is not equal to zero
if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[FAIL] ${LVL_1_SCRIPT_NAME}: At least one of the tests failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All test passed."
fi
