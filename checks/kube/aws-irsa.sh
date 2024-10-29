#!/bin/bash

set -o pipefail

# Script to check IRSA configuration for AWS Kubernetes only
# what is IRSA ? https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Default variables
NAMESPACE=""
SCRIPT_STATUS_OUTPUT=0
CHART_NAME="camunda-platform"
# List of components from the Helm chart to check for IRSA
# The first list is for components that need IRSA for OpenSearch/Elasticsearch
COMPONENTS_TO_CHECK_IRSA_ELASTIC="zeebe,operate,tasklist,optimize"

# The second list is for components that need IRSA to authenticate to PostgreSQL
COMPONENTS_TO_CHECK_IRSA_PG="identityKeycloak,identity,webModeler"

# Minimum required AWS CLI versions
REQUIRED_AWSCLI_VERSION_V2="2.12.3"
REQUIRED_AWSCLI_VERSION_V1="1.27.160"

# Usage message
usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-e EXCLUDE_COMPONENTS] [-p COMPONENTS_PG] [-l COMPONENTS_ELASTIC]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use"
    echo "  -e EXCLUDE_COMPONENTS           Comma-separated list of Components to exclude from the check (reference of the component is the root key used in the chart)"
    echo "  -p COMPONENTS_PG                Comma-separated list of Components to check IRSA for PostgreSQL (overrides default list: $COMPONENTS_TO_CHECK_IRSA_PG)"
    echo "  -l COMPONENTS_ELASTIC           Comma-separated list of Components to check IRSA for OpenSearch/Elasticsearch (overrides default list: $COMPONENTS_TO_CHECK_IRSA_ELASTIC)"
    exit 1
}

# Parse command line options
while getopts ":hn:e:p:l:" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
            ;;
        e)
            EXCLUDE_COMPONENTS=$OPTARG
            ;;
        p)
            COMPONENTS_TO_CHECK_IRSA_PG=$OPTARG
            ;;
        l)
            COMPONENTS_TO_CHECK_IRSA_ELASTIC=$OPTARG
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

echo "[INFO] Components to check for IRSA (PostgreSQL): $COMPONENTS_TO_CHECK_IRSA_PG"
echo "[INFO] Components to check for IRSA (Elasticsearch/OpenSearch): $COMPONENTS_TO_CHECK_IRSA_ELASTIC"
echo "[INFO] Components to exclude from IRSA checks: $EXCLUDE_COMPONENTS"

# Exclude components from check if specified
IFS=',' read -r -a EXCLUDE_COMPONENTS_ARRAY <<< "$EXCLUDE_COMPONENTS"

# pre-check requirements
command -v jq >/dev/null 2>&1 || { echo >&2 "Error: jq is required but not installed. Please install it (https://jqlang.github.io/jq/download/). Aborting."; exit 1; }
command -v yq >/dev/null 2>&1 || { echo >&2 "Error: yq is required but not installed. Please install it (https://mikefarah.gitbook.io/yq/v3.x). Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "Error: helm is required but not installed. Please install it (https://helm.sh/docs/intro/install/). Aborting."; exit 1; }
command -v aws >/dev/null 2>&1 || { echo >&2 "Error: awscli is required but not installed. Please install it (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Aborting."; exit 1; }

# AWS CLI version check function
check_awscli_version() {
    aws_version=$(aws --version 2>&1 | cut -d / -f2 | cut -d ' ' -f1)
    if [[ $aws_version == 2.* ]]; then
        required_version=$REQUIRED_AWSCLI_VERSION_V2
    else
        required_version=$REQUIRED_AWSCLI_VERSION_V1
    fi

    # Compare versions
    if [[ "$(printf '%s\n' "$required_version" "$aws_version" | sort -V | head -n1)" != "$required_version" ]]; then
        echo "[FAIL] AWS CLI version $aws_version is below the required version $required_version. Please update it. Aborting." 1>&2
        exit 1
    fi

    # Verify AWS CLI is configured and user is logged in
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "Error: AWS CLI is not properly configured or you are not logged in. Please configure it. Aborting."
        exit 1
    fi
    echo "[OK] AWS CLI version $aws_version is compatible and user is logged in."
}
check_awscli_version

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
        echo "[FAIL] This script is designed for AWS clusters only. No AWS nodes detected." 1>&2
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
        echo "[FAIL] Chart $CHART_NAME is not found in namespace $NAMESPACE." 1>&2
        SCRIPT_STATUS_OUTPUT=4
    fi
}

check_helm_deployment

HELM_CHART_VALUES=""
HELM_RELEASE_NAME=""
HELM_CHART_VERSION=""
retrieve_helm_deployment_values() {
    echo "[INFO] Retrieving values for the for Helm deployment in namespace $NAMESPACE for chart $CHART_NAME."

    chart_name_command="echo '$CAMUNDA_HELM_CHART_DEPLOYMENT' | jq -r '.name'"
    echo "[INFO] Running command: ${chart_name_command}"
    HELM_RELEASE_NAME=$(eval "${chart_name_command}")

    helm_values_command="helm -n \"$NAMESPACE\" get values \"$HELM_RELEASE_NAME\" -o json"
    echo "[INFO] Running command: ${helm_values_command}"
    HELM_CHART_VALUES=$(eval "${helm_values_command}")

    helm_chart_version_command="echo '$CAMUNDA_HELM_CHART_DEPLOYMENT' | jq -r '.chart'"
    echo "[INFO] Running command: ${helm_chart_version_command}"
    HELM_CHART_VERSION=$(eval "${helm_chart_version_command}")


    if [[ -n "$HELM_CHART_VALUES" ]]; then
        echo "[OK] Chart $CHART_NAME ($HELM_RELEASE_NAME) is deployed with the following values: $HELM_CHART_VALUES."
    else
        echo "[FAIL] Chart $CHART_NAME ($HELM_RELEASE_NAME) values cannot be retrieved." 1>&2
        SCRIPT_STATUS_OUTPUT=5
    fi
}
if [ "$SCRIPT_STATUS_OUTPUT" -eq 0 ]; then
  retrieve_helm_deployment_values
fi

echo "Values of the deployed chart:"
echo "$HELM_CHART_VALUES" | jq

# Retrieve default value of the chart
HELM_CHART_DEFAULT_VALUES=""
get_helm_chart_default_values() {    
    # Extract chart name and version from the HELM_CHART_VERSION variable
    local CHART_NAME
    local VERSION

    if [[ -n "$HELM_CHART_VERSION" ]]; then
        CHART_NAME=$(echo "$HELM_CHART_VERSION" | cut -d'-' -f1-2)
        VERSION=$(echo "$HELM_CHART_VERSION" | cut -d'-' -f3)
    else
        echo "[FAIL] HELM_CHART_VERSION is not set." 1>&2
        exit 1
    fi

    # Add the Camunda Helm repository
    helm_repo_command="helm repo add camunda https://helm.camunda.io"
    echo "[INFO] Running command: ${helm_repo_command}"
    helm_repo_output=$(eval "$helm_repo_command" 2>&1)

    if [ $? -eq 0 ]; then
        echo "[OK] Added Helm repository."
    else
        echo "[FAIL] Failed to add Helm repository: $helm_repo_output" 1>&2
        exit 1
    fi

    # Update the Helm repository
    helm_update_command="helm repo update"
    echo "[INFO] Running command: ${helm_update_command}"
    helm_update_output=$(eval "$helm_update_command" 2>&1)

    if [ $? -eq 0 ]; then
        echo "[OK] Updated Helm repository."
    else
        echo "[FAIL] Failed to update Helm repository: $helm_update_output" 1>&2
        exit 1
    fi

    # Retrieve the default values and store them in a variable
    helm_values_command="helm show values camunda/$CHART_NAME --version \"$VERSION\" | yq eval -o=json -"
    echo "[INFO] Running command: ${helm_values_command}"
    HELM_CHART_DEFAULT_VALUES=$(eval "$helm_values_command" 2>&1)

    if [ $? -eq 0 ]; then
        echo "[OK] Retrieved default values from the chart."
    else
        echo "[FAIL] Failed to retrieve default values from the chart: $HELM_CHART_DEFAULT_VALUES" 1>&2
        exit 1
    fi
}
get_helm_chart_default_values

# Function to retrieve service account names for each component
PG_SERVICE_ACCOUNTS=""
OS_SERVICE_ACCOUNTS=""
get_service_account_name() {
    local component_list=$1
    local category=$2
    local service_accounts_map="{}"

    # Iterate over each component
    IFS=',' read -r -a components <<< "$component_list"
    for component in "${components[@]}"; do

        if [[ " ${EXCLUDE_COMPONENTS_ARRAY[*]} " == *" $component "* ]]; then
            echo "[INFO] Skipping excluded component: $component"
            continue
        fi

        # Check if component is enabled in HELM_CHART_VALUES
        enabled_value=$(echo "$HELM_CHART_VALUES" | jq -r --arg comp "$component" '.[$comp].enabled')
        if [ "$enabled_value" == "null" ]; then
            enabled_value=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r --arg comp "$component" '.[$comp].enabled')
        fi

        if [[ "$enabled_value" == "false" ]]; then
            echo "[INFO] Component $component is disabled, skipping verification."
            continue
        fi

        # Retrieve serviceAccount name from HELM_CHART_VALUES
        service_account_name=$(echo "$HELM_CHART_VALUES" | jq -r --arg comp "$component" '.[$comp].serviceAccount.name // empty')

        # Use default naming if no serviceAccount name is found in values
        if [[ -z "$service_account_name" ]]; then
            service_account_name="${HELM_RELEASE_NAME}-${component}"
            echo "[INFO] Component $component has no custom service account name ($component.serviceAccount.name), falling back on default: $service_account_name."
        fi

        # Add to JSON mapping
        service_accounts_map=$(echo "$service_accounts_map" | jq --arg comp "$component" --arg sa "$service_account_name" '. + {($comp): {"serviceAccountName": $sa}}')
    done

    # Assign the result to the appropriate category variable
    if [[ "$category" == "pg" ]]; then
        PG_SERVICE_ACCOUNTS="$service_accounts_map"
    elif [[ "$category" == "elastic" ]]; then
        OS_SERVICE_ACCOUNTS="$service_accounts_map"
    fi
}

# Retrieve and map service accounts for each component category
if [[ -n "$HELM_CHART_VALUES" ]]; then
    echo "[INFO] Creating service account mappings for components."

    get_service_account_name "$COMPONENTS_TO_CHECK_IRSA_PG" "pg"
    get_service_account_name "$COMPONENTS_TO_CHECK_IRSA_ELASTIC" "elastic"

    echo "[INFO] PostgreSQL Components Service Account Mapping:"
    if ! echo "$PG_SERVICE_ACCOUNTS" | jq .; then
        echo "[ERROR] Failed to parse PostgreSQL service account mapping JSON. Please check the Helm chart values." >&2
        exit 1
    fi

    echo "[INFO] Elasticsearch/OpenSearch Components Service Account Mapping:"
    if ! echo "$OS_SERVICE_ACCOUNTS" | jq .; then
        echo "[ERROR] Failed to parse Elasticsearch/OpenSearch service account mapping JSON. Please check the Helm chart values." >&2
        exit 1
    fi

else
    echo "[FAIL] Cannot retrieve Helm chart values; unable to check service accounts." >&2
    exit 1
fi

 check_service_account_enabled() {
    local component="$1"
    local service_accounts="$2"

    # Check if {component].serviceAccount.enabled exists in HELM_CHART_VALUES first otherwise, fallback on default
    enabled_value=$(echo "$service_accounts" | jq -r --arg comp "$component" '.[$comp].serviceAccount.enabled')
    if [[ "$enabled_value" == "null" ]]; then
        enabled_value=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r --arg comp "$component" '.[$comp].serviceAccount.enabled')
    fi

    # Check if the serviceAccount is disabled
    if [[ "$enabled_value" == "false" ]]; then
        echo "[FAIL] Cannot expect IRSA to work if service account for $component is not enabled ($component.serviceAccount.enabled: false). You can exclude it from the checks using EXCLUDE_COMPONENTS arg." 1>&2
        SCRIPT_STATUS_OUTPUT=6
    else 
        echo "[OK] Service account for $component is enabled"
    fi
}

# Function to check if the eks.amazonaws.com/role-arn annotation is present and not empty
check_role_arn_annotation_service_account() {
    local service_account_name="$1"
    local component_name=$2
    local category=$3

    echo "[INFO] Check present of eks.amazonaws.com/role-arn annotation on the serviceAccount $service_account_name"
    local kubectl_command="kubectl get serviceaccount \"$service_account_name\" -n \"$NAMESPACE\" -o json"
    echo "[INFO] Running command: $kubectl_command"
    annotations=$(eval "$kubectl_command")
    echo "[INFO] Command output: $annotations"

    role_arn=$(echo "$annotations" | jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"]')

    if [[ -z "$role_arn" ]]; then
        echo "[FAIL] The service account $service_account_name does not have a valid eks.amazonaws.com/role-arn annotation. You must add it in the chart, see https://docs.camunda.io/docs/self-managed/setup/deploy/amazon/amazon-eks/eks-helm/" 1>&2
        SCRIPT_STATUS_OUTPUT=7
    else 
        echo "[OK] The service account $service_account_name is bound to the role $role_arn by the eks.amazonaws.com/role-arn annotation."
        
        # Assign the result to the appropriate category variable
        if [[ "$category" == "pg" ]]; then
            PG_SERVICE_ACCOUNTS=$(echo "$PG_SERVICE_ACCOUNTS" | jq --arg comp "$component_name" --arg arn "$role_arn" '.[$comp].roleArn = $arn')
        elif [[ "$category" == "elastic" ]]; then
            OS_SERVICE_ACCOUNTS=$(echo "$OS_SERVICE_ACCOUNTS" | jq --arg comp "$component_name" --arg arn "$role_arn" '.[$comp].roleArn = $arn')
        fi
    fi
}

# Check PostgreSQL service accounts are enabled
for component in $(echo "$PG_SERVICE_ACCOUNTS" | jq -r 'keys[]'); do
    check_service_account_enabled "$component" "$PG_SERVICE_ACCOUNTS"

    service_account_name=$(echo "$PG_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].serviceAccountName')
    if [[ -z "$service_account_name" ]]; then
        echo "[FAIL] Service account name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=8
        continue 
    fi

    check_role_arn_annotation_service_account "$service_account_name" "$component" "pg"
done

# Check Elasticsearch/OpenSearch service accounts are enabled
for component in $(echo "$OS_SERVICE_ACCOUNTS" | jq -r 'keys[]'); do
    check_service_account_enabled "$component" "$OS_SERVICE_ACCOUNTS"
    
    service_account_name=$(echo "$OS_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].serviceAccountName')
    if [[ -z "$service_account_name" ]]; then
        echo "[FAIL] Service account name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=8
        continue 
    fi

    check_role_arn_annotation_service_account "$service_account_name" "$component" "elastic"
done

echo "$OS_SERVICE_ACCOUNTS"


exit 6

# check that the role-arn is valid by querying with aws cli
# check on the components that they use this service account
# Check that the role has a trust policy that allows it to access the target resource

# check EKS
# aws eks describe-cluster --name cluster_name --query "cluster.identity.oidc.issuer" --output text
# check that kubernetes version is > 1.23 https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html

# check postgres
# check that the instance is healthy
# check that the connectivity between the eks cluster and the instance exists
# check that iam is enabled
# check that the target has an allowed access policy
# apply a check by deploying an amazonlinux pod and perform a curl + aws whoami, if it fails, inidcates to double check the policy indicated


# check opensearch
# check that the instance is healthy
# check that the connectivity between the eks cluster and the instance exists
# check that iam is enabled
# check that the target has an allowed access policy
# apply a check by deploying an amazonlinux pod and perform a curl + aws whoami, if it fails, inidcates to double check the policy indicated

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
        echo "[FAIL] Service Account $service_account_name does not have the correct IAM Role bound. Expected: $iam_role_arn, Found: $sa_iam_role." 1>&2
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
        echo "[FAIL] IAM Role $iam_role_arn does not have the correct trust policy for EKS. Found: $trust_policy." 1>&2
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
        echo "[FAIL] IAM Role $iam_role_arn does not have the required permissions. Policies attached: $policies." 1>&2
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
