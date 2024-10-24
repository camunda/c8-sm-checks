#!/bin/bash

set -o pipefail

# Script to check IRSA configuration for AWS Kubernetes only
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Default variables
NAMESPACE=""
SCRIPT_STATUS_OUTPUT=0
CHART_NAME="camunda-platform"

# Usage message
usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-e EXCLUDE_SA]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use"
    echo "  -e EXCLUDE_COMPONENTS           Comma-separated list of Components to exclude from the check (reference of the component is the root key used in the chart)"
    exit 1
}

# Parse command line options
while getopts ":hn:e:" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
            ;;
        e)
            EXCLUDE_SA=$OPTARG
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

# Check if required option NAMESPACE is provided
if [ -z "$NAMESPACE" ]; then
    echo "Error: Missing one of the required options (list of all required options: NAMESPACE)." 1>&2
    usage
fi

# pre-check requirements
command -v jq >/dev/null 2>&1 || { echo >&2 "Error: jq is required but not installed. Please install it (https://jqlang.github.io/jq/download/). Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "Error: helm is required but not installed. Please install it (https://helm.sh/docs/intro/install/). Aborting."; exit 1; }

# Check if running on AWS by looking for AWS-specific labels on the worker nodes
check_aws_environment() {
    echo "[INFO] Checking if the cluster is running on AWS."

    aws_check="kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'"
    echo "[INFO] Running command: ${aws_check}"
    aws_check_output=$(eval "${aws_check}")

    # Fetch the nodes and look for AWS specific labels
    if echo "$aws_check_output" | grep -q 'aws'; then
        echo "[OK] AWS environment detected. Proceeding with the script."
    else
        echo "[FAIL] This script is designed for AWS clusters only. No AWS nodes detected." >&2
        exit 1
    fi
}

check_aws_environment

# Check if a Helm deployment exists in the namespace
CAMUNDA_HELM_CHART_DEPLOYMENT=""
check_helm_deployment() {
    echo "[INFO] Checking for Helm deployment in namespace $NAMESPACE for chart $CHART_NAME."


    helm_command="helm list -n \"$NAMESPACE\" -o json"
    echo "[INFO] Running command: ${helm_command}"
    helm_list_output=$(eval "${helm_command}")

    echo "[INFO] List of helm charts installed in the namespace: $helm_list_output"
  
    camunda_chart_command="echo '$helm_list_output' | jq -c '.[] | select(.chart | startswith(\"camunda-platform-\"))'"
    CAMUNDA_HELM_CHART_DEPLOYMENT=$(eval "${camunda_chart_command}")

    if [[ -n "$CAMUNDA_HELM_CHART_DEPLOYMENT" ]]; then
        echo "[OK] Chart $CHART_NAME is deployed in namespace $NAMESPACE: $CAMUNDA_HELM_CHART_DEPLOYMENT."
    else
        echo "[FAIL] Chart $CHART_NAME is not found in namespace $NAMESPACE." >&2
        SCRIPT_STATUS_OUTPUT=4
    fi
}

check_helm_deployment

HELM_CHART_VALUES=""
retrieve_helm_deployment_values() {
    echo "[INFO] Retrieving values for the for Helm deployment in namespace $NAMESPACE for chart $CHART_NAME."

    chart_name_command="echo '$CAMUNDA_HELM_CHART_DEPLOYMENT' | jq -r '.name'"
    echo "[INFO] Running command: ${chart_name_command}"
    helm_name=$(eval "${chart_name_command}")

    helm_values_command="helm -n \"$NAMESPACE\" get values \"$helm_name\" -o json"
    echo "[INFO] Running command: ${helm_values_command}"
    HELM_CHART_VALUES=$(eval "${helm_values_command}")


    if [[ -n "$HELM_CHART_VALUES" ]]; then
        echo "[OK] Chart $CHART_NAME ($helm_name) is deployed with the following values: $HELM_CHART_VALUES."
    else
        echo "[FAIL] Chart $CHART_NAME ($helm_name) values cannot be retrieved." >&2
        SCRIPT_STATUS_OUTPUT=5
    fi
}
if [ "$SCRIPT_STATUS_OUTPUT" -eq 0 ]; then
  retrieve_helm_deployment_values
fi

echo "$HELM_CHART_VALUES" | jq

exit 1



# Exclude service accounts from check if specified
IFS=',' read -r -a exclude_array <<< "$EXCLUDE_SA"

# Function to check service account IAM role binding
check_service_account_iam_role() {
    local service_account_name=$1
    local iam_role_arn=$2

    echo "[INFO] Checking Service Account $service_account_name in namespace $NAMESPACE for IAM Role $iam_role_arn."

    # Retrieve IAM Role ARN annotation from the service account
    local sa_iam_role
    sa_iam_role=$(kubectl get serviceaccount "$service_account_name" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')

    if [ "$sa_iam_role" == "$iam_role_arn" ]; then
        echo "[OK] Service Account $service_account_name has the IAM Role $iam_role_arn bound correctly."
    else
        echo "[FAIL] Service Account $service_account_name does not have the correct IAM Role bound. Expected: $iam_role_arn, Found: $sa_iam_role." >&2
        SCRIPT_STATUS_OUTPUT=1
    fi
}

# Function to check the IAM Role trust policy
check_iam_role_trust_policy() {
    local iam_role_arn=$1

    echo "[INFO] Checking IAM Role $iam_role_arn trust policy."

    local trust_policy
    trust_policy=$(aws iam get-role --role-name "$(basename "$iam_role_arn")" --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)

    if [[ "$trust_policy" == *"eks.amazonaws.com"* ]]; then
        echo "[OK] IAM Role $iam_role_arn has the correct trust policy for EKS."
    else
        echo "[FAIL] IAM Role $iam_role_arn does not have the correct trust policy for EKS. Found: $trust_policy." >&2
        SCRIPT_STATUS_OUTPUT=2
    fi
}

# Function to check IAM Role permissions
check_iam_role_permissions() {
    local iam_role_arn=$1

    echo "[INFO] Checking permissions for IAM Role $iam_role_arn."

    local policies
    policies=$(aws iam list-attached-role-policies --role-name "$(basename "$iam_role_arn")" --query 'AttachedPolicies[*].PolicyName' --output text)

    if [[ "$policies" == *"AmazonEKSWorkerNodePolicy"* ]]; then
        echo "[OK] IAM Role $iam_role_arn has the necessary permissions."
    else
        echo "[FAIL] IAM Role $iam_role_arn does not have the required permissions. Policies attached: $policies." >&2
        SCRIPT_STATUS_OUTPUT=3
    fi
}

# Loop through each service account and check its configuration unless it is excluded
for sa_name in "${!service_accounts[@]}"; do
    sa_role="${service_accounts[$sa_name]}"

    if [[ " ${exclude_array[*]} " != *"$sa_name"* ]]; then
        check_service_account_iam_role "$sa_name" "$sa_role"
        check_iam_role_trust_policy "$sa_role"
        check_iam_role_permissions "$sa_role"
    else
        echo "[INFO] Skipping Service Account $sa_name as per user request."
    fi
done

# Check for script failure
if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[FAIL] ${LVL_1_SCRIPT_NAME}: At least one of the checks failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All checks passed."
fi
