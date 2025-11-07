#!/bin/bash

set -o pipefail

# Script to check IRSA configuration for AWS Kubernetes only
# what is IRSA ? https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Default variables
NAMESPACE="${NAMESPACE:-""}"
SCRIPT_STATUS_OUTPUT=0
CHART_NAME="camunda-platform"
SPAWN_POD=true  # By default, the pod will spawn for verification

# List of components from the Helm chart to check for IRSA
# The first list is for components that need IRSA for OpenSearch
COMPONENTS_TO_CHECK_IRSA_OS="orchestration,optimize"

# The second list is for components that need IRSA to authenticate to PostgreSQL
COMPONENTS_TO_CHECK_IRSA_PG="identityKeycloak,identity,webModeler"

EXCLUDE_COMPONENTS="${EXCLUDE_COMPONENTS:-""}"


# Associative array for case-insensitive component mapping
COMPONENT_MAPPING=(
    "orchestration:orchestration"
    "optimize:optimize"
    "identitykeycloak:identityKeycloak"
    "identity:identity"
    "webmodeler:webModeler"
)

# Minimum required AWS CLI versions
REQUIRED_AWSCLI_VERSION_V2="2.12.3"
REQUIRED_AWSCLI_VERSION_V1="1.27.160"

# Usage message
usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-e EXCLUDE_COMPONENTS] [-p] [-l] [-s]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use (required)"
    echo "  -e EXCLUDE_COMPONENTS           Comma-separated list of Components to exclude from the check (reference of the component is the root key used in the chart)"
    echo "  -p                              Comma-separated list of Components to check IRSA for PostgreSQL (overrides default list: $COMPONENTS_TO_CHECK_IRSA_PG)"
    echo "  -l                              Comma-separated list of Components to check IRSA for OpenSearch (overrides default list: $COMPONENTS_TO_CHECK_IRSA_OS)"
    echo "  -s                              Disable pod spawn for IRSA and connectivity verification."
    echo "                                  By default, the script spawns jobs in the specified namespace to perform"
    echo "                                  IRSA checks and network connectivity tests. These jobs use the amazonlinux:latest"
    echo "                                  image and scan with nmap to verify connectivity."
    exit 1
}
# Convert user input to lowercase and map it to the case-sensitive component names
normalize_components() {
    input="$1"
    normalized_components=()

    # Split input by comma and process each component
    IFS=',' read -ra components <<< "$input"
    for component in "${components[@]}"; do
        lower_component=$(echo "$component" | tr '[:upper:]' '[:lower:]')

        for mapping in "${COMPONENT_MAPPING[@]}"; do
            key=${mapping%%:*}
            value=${mapping#*:}

            if [[ "$lower_component" == "$key" ]]; then
                normalized_components+=("$value")
                break
            fi
        done
    done

    # Join normalized components back with commas
    echo "${normalized_components[*]}" | tr ' ' ','
}


# Parse command line options
while getopts ":hn:e:p:l:s" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
            ;;
        e)
            EXCLUDE_COMPONENTS=$(normalize_components "$OPTARG")
            ;;
        p)
            COMPONENTS_TO_CHECK_IRSA_PG=$(normalize_components "$OPTARG")
            ;;
        l)
            COMPONENTS_TO_CHECK_IRSA_OS=$(normalize_components "$OPTARG")
            ;;
        s)
            SPAWN_POD=false
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
echo "[INFO] Components to check for IRSA (OpenSearch): $COMPONENTS_TO_CHECK_IRSA_OS"
echo "[INFO] Components to exclude from IRSA checks: $EXCLUDE_COMPONENTS"

# Exclude components from check if specified
EXCLUDE_COMPONENTS_ARRAY=()
if [[ -n "$EXCLUDE_COMPONENTS" ]]; then
    IFS=',' read -r -a EXCLUDE_COMPONENTS_ARRAY <<< "$EXCLUDE_COMPONENTS"
fi

if [[ ${#EXCLUDE_COMPONENTS_ARRAY[@]} -gt 0 ]]; then
    EXCLUDE_PATTERN=$(printf "%s\n" "${EXCLUDE_COMPONENTS_ARRAY[@]}" | sed 's/^/\\b&\\b/' | tr '\n' '|' | sed 's/|$//')
else
    EXCLUDE_PATTERN=""
fi

# pre-check requirements
command -v jq >/dev/null 2>&1 || { echo 1>&2 "Error: jq is required but not installed. Please install it (https://jqlang.github.io/jq/download/). Aborting."; exit 1; }
command -v yq >/dev/null 2>&1 || { echo 1>&2 "Error: yq is required but not installed. Please install it (https://mikefarah.gitbook.io/yq/v3.x). Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo 1>&2 "Error: helm is required but not installed. Please install it (https://helm.sh/docs/intro/install/). Aborting."; exit 1; }
command -v aws >/dev/null 2>&1 || { echo 1>&2 "Error: awscli is required but not installed. Please install it (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Aborting."; exit 1; }

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

    echo "[INFO] List of Helm charts installed in the namespace: $helm_list_output"

    camunda_chart_command="echo '$helm_list_output' | jq -c '.[] | select(.chart | startswith(\"camunda-platform-\"))'"
    CAMUNDA_HELM_CHART_DEPLOYMENT=$(eval "${camunda_chart_command}")

    if [[ -n "$CAMUNDA_HELM_CHART_DEPLOYMENT" && "$CAMUNDA_HELM_CHART_DEPLOYMENT" != "null" ]]; then
        echo "[OK] Chart $CHART_NAME is deployed in namespace $NAMESPACE: $CAMUNDA_HELM_CHART_DEPLOYMENT."
    else
        echo "[FAIL] Chart $CHART_NAME is not found in namespace $NAMESPACE." 1>&2
        echo "[INFO] It appears that $CHART_NAME may not have been deployed with Helm directly. If you used 'helm template' or another method, please note that these are not supported by this check." 1>&2
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

    if [[ -z "$HELM_RELEASE_NAME" || "$HELM_RELEASE_NAME" == "null" ]]; then
        echo "[FAIL] Failed to found the helm release name: $HELM_RELEASE_NAME" 1>&2
        SCRIPT_STATUS_OUTPUT=5
    fi

    helm_values_command="helm -n \"$NAMESPACE\" get values \"$HELM_RELEASE_NAME\" -o json"
    echo "[INFO] Running command: ${helm_values_command}"
    HELM_CHART_VALUES=$(eval "${helm_values_command}")

    if [[ -z "$HELM_CHART_VALUES" ]]; then
        echo "[FAIL] Failed to retrieve helm values for $HELM_RELEASE_NAME" 1>&2
        SCRIPT_STATUS_OUTPUT=5
    fi

    helm_chart_version_command="echo '$CAMUNDA_HELM_CHART_DEPLOYMENT' | jq -r '.chart'"
    echo "[INFO] Running command: ${helm_chart_version_command}"
    HELM_CHART_VERSION=$(eval "${helm_chart_version_command}")


    if [[ -z "$HELM_CHART_VERSION" || "$HELM_CHART_VERSION" == "null" ]]; then
        echo "[FAIL] Failed to capture version for helm chart deployment $HELM_RELEASE_NAME: $HELM_CHART_VERSION" 1>&2
        SCRIPT_STATUS_OUTPUT=5
    fi

    major_version=$(echo "$HELM_CHART_VERSION" | sed 's/^.*-//' | cut -d '.' -f 1)
    if (( major_version < 11 )); then
        echo "[WARNING] This script has only been tested with chart versions 11.x.x and above, you are using $HELM_CHART_VERSION."
    fi

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
    chart_name=""
    version=""

    if [[ -n "$HELM_CHART_VERSION" ]]; then
        chart_name=$(echo "$HELM_CHART_VERSION" | cut -d'-' -f1-2)
        version=$(echo "$HELM_CHART_VERSION" | cut -d'-' -f3)
    else
        echo "[FAIL] HELM_CHART_VERSION is not set." 1>&2
        exit 1
    fi

    # Check if version is 0.0.0 (snapshot)
    if [[ "$version" == "0.0.0" ]]; then
        echo "[INFO] Detected snapshot version 0.0.0, retrieving app version to fetch values from GitHub."
        command -v curl >/dev/null 2>&1 || { echo 1>&2 "Error: curl is required but not installed. Please install it. Aborting."; exit 1; }

        # Get app version from deployed chart
        app_version_command="echo '$CAMUNDA_HELM_CHART_DEPLOYMENT' | jq -r '.app_version'"
        echo "[INFO] Running command: ${app_version_command}"
        app_version=$(eval "${app_version_command}")

        if [[ -z "$app_version" || "$app_version" == "null" ]]; then
            echo "[FAIL] Failed to retrieve app version from deployment." 1>&2
            exit 1
        fi

        echo "[INFO] Found app version: $app_version"

        # Extract major.minor version (e.g., "8.9.x" -> "8.9")
        chart_version=$(echo "$app_version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')

        if [[ -z "$chart_version" ]]; then
            echo "[FAIL] Failed to parse chart version from app version: $app_version" 1>&2
            exit 1
        fi

        echo "[INFO] Using chart version: $chart_version"

        # Download values from GitHub
        github_url="https://raw.githubusercontent.com/camunda/camunda-platform-helm/refs/heads/main/charts/camunda-platform-${chart_version}/values.yaml"
        echo "[INFO] Downloading values from: $github_url"

        helm_values_command="curl -fsSL \"$github_url\" | yq eval -o=json -"
        echo "[INFO] Running command: ${helm_values_command}"
        HELM_CHART_DEFAULT_VALUES=$(eval "$helm_values_command" 2>&1)

        # shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            echo "[OK] Retrieved default values from GitHub."
        else
            echo "[FAIL] Failed to retrieve default values from GitHub: $HELM_CHART_DEFAULT_VALUES" 1>&2
            exit 1
        fi
    else
        # Normal flow for non-snapshot versions
        # Add the Camunda Helm repository
        helm_repo_command="helm repo add camunda https://helm.camunda.io"
        echo "[INFO] Running command: ${helm_repo_command}"
        helm_repo_output=$(eval "$helm_repo_command" 2>&1)

        # shellcheck disable=SC2181
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

        # shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            echo "[OK] Updated Helm repository."
        else
            echo "[FAIL] Failed to update Helm repository: $helm_update_output" 1>&2
            exit 1
        fi

        # Retrieve the default values and store them in a variable
        helm_values_command="helm show values camunda/$chart_name --version \"$version\" | yq eval -o=json -"
        echo "[INFO] Running command: ${helm_values_command}"
        HELM_CHART_DEFAULT_VALUES=$(eval "$helm_values_command" 2>&1)

        # shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            echo "[OK] Retrieved default values from the chart."
        else
            echo "[FAIL] Failed to retrieve default values from the chart: $HELM_CHART_DEFAULT_VALUES" 1>&2
            exit 1
        fi
    fi
}
get_helm_chart_default_values

check_eks_cluster() {
    # Get the Kubernetes control plane URL
    cluster_info=$(kubectl cluster-info)
    control_plane_url=$(echo "$cluster_info" | grep 'Kubernetes control plane' | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')

    if [[ -z "$control_plane_url" ]]; then
        echo "[FAIL] Unable to retrieve Kubernetes control plane URL." >&2
        SCRIPT_STATUS_OUTPUT=30
        return
    fi

    echo "[INFO] Control plane URL: $control_plane_url"

    # Extract the region from the control plane URL
    region=$(echo "$control_plane_url" | awk -F'.' '{print $(NF-3)}')
    echo "[INFO] Derived region: $region from control plane URL."

    # Describe the EKS clusters in the specified region
    eks_clusters_command="aws eks list-clusters --region \"$region\" --query 'clusters[*]' --output text"
    echo "[INFO] Running command: $eks_clusters_command"
    eks_clusters=$(eval "$eks_clusters_command")

    if [[ -z "$eks_clusters" ]]; then
        echo "[FAIL] No EKS clusters found in region $region." >&2
        SCRIPT_STATUS_OUTPUT=31
        return
    fi

    echo "[INFO] Found EKS clusters in region $region: $eks_clusters"

    # Loop through each EKS cluster to find the matching one
    cluster_found=false
    # Convert space/tab separated list to array and iterate
    for cluster_name in $eks_clusters; do
        # Describe the cluster to get the control plane URL
        eks_describe_command="aws eks describe-cluster --name \"$cluster_name\" --region \"$region\" --query 'cluster.endpoint' --output text"
        echo "[INFO] Running command: $eks_describe_command"
        eks_control_plane_url=$(eval "$eks_describe_command")

        # Check if there are any hidden characters
        if [[ "$eks_control_plane_url" == "$control_plane_url" ]]; then
            echo "[OK] Matching EKS cluster found: $cluster_name with control plane URL: $eks_control_plane_url."
            cluster_found=true
            break
        fi
    done

    if [[ "$cluster_found" == false ]]; then
        echo "[FAIL] No matching EKS cluster found for control plane URL: $control_plane_url." >&2
        SCRIPT_STATUS_OUTPUT=32
    fi

    # Retrieve the OIDC Issuer URL for the EKS cluster
    oidc_command="aws eks describe-cluster --name \"$cluster_name\" --query \"cluster.identity.oidc.issuer\" --output text --region \"$region\""
    echo "[INFO] Running command: $oidc_command"
    oidc_issuer=$(eval "$oidc_command")

    if [[ "$oidc_issuer" == "None" || -z "$oidc_issuer" ]]; then
        echo "[FAIL] OIDC is not enabled on EKS cluster $cluster_name. Ensure OIDC is configured for the cluster." >&2
        SCRIPT_STATUS_OUTPUT=33
    else
        echo "[OK] OIDC is enabled on EKS cluster $cluster_name with issuer: $oidc_issuer"
    fi

    # Retrieve the Kubernetes version for the EKS cluster
    version_command="aws eks describe-cluster --name \"$cluster_name\" --query \"cluster.version\" --output text --region \"$region\""
    echo "[INFO] Running command: $version_command"
    kubernetes_version=$(eval "$version_command")

    version_check=$(echo -e "1.23\n$kubernetes_version" | awk '{if ($1 > $2) {print "greater"} else {print "less_or_equal"}}')

    if [[ "$version_check" == "less_or_equal" ]]; then
        echo "[FAIL] Kubernetes version $kubernetes_version on EKS cluster $cluster_name is below the minimum required version 1.23 for IAM role integration (https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html)." >&2
        SCRIPT_STATUS_OUTPUT=34
    else
        echo "[OK] Kubernetes version $kubernetes_version on EKS cluster $cluster_name meets the minimum version requirement (≥1.23)."
    fi

    # Verify that IAM OIDC identity provider is configured
    iam_oidc_check_command="aws iam list-open-id-connect-providers --query \"OpenIDConnectProviderList[?ends_with(Arn, '${oidc_issuer##*/}')].Arn\" --output text"
    echo "[INFO] Running command: $iam_oidc_check_command"
    iam_oidc_check=$(eval "$iam_oidc_check_command")

    if [[ -z "$iam_oidc_check" ]]; then
        echo "[FAIL] IAM OIDC identity provider is not enabled for EKS cluster $cluster_name. Please enable it for IRSA support." >&2
        SCRIPT_STATUS_OUTPUT=35
    else
        echo "[OK] IAM OIDC identity provider is enabled for EKS cluster $cluster_name."
    fi
}

check_eks_cluster


# Function to retrieve service account names for each component
PG_SERVICE_ACCOUNTS=""
OS_SERVICE_ACCOUNTS=""
get_service_account_name() {
    component_list=$1
    category=$2
    service_accounts_map="{}"

    # Iterate over each component
    IFS=',' read -r -a components <<< "$component_list"
    for component in "${components[@]}"; do

        if [[ $component =~ $EXCLUDE_PATTERN ]]; then
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
        if [[ -z "$service_account_name" ||  "$service_account_name" == "null"  ]]; then
            service_account_name="${HELM_RELEASE_NAME}-${component}"
            echo "[INFO] Component $component has no custom service account name ($component.serviceAccount.name), falling back on default: $service_account_name."
        fi

        # Add to JSON mapping
        service_accounts_map=$(echo "$service_accounts_map" | jq --arg comp "$component" --arg sa "$service_account_name" '. + {($comp): {"serviceAccountName": $sa}}')
    done

    # Assign the result to the appropriate category variable
    if [[ "$category" == "pg" ]]; then
        PG_SERVICE_ACCOUNTS="$service_accounts_map"
    elif [[ "$category" == "os" ]]; then
        OS_SERVICE_ACCOUNTS="$service_accounts_map"
    fi
}

# Retrieve and map service accounts for each component category
if [[ -n "$HELM_CHART_VALUES" ]]; then
    echo "[INFO] Creating service account mappings for components."

    get_service_account_name "$COMPONENTS_TO_CHECK_IRSA_PG" "pg"
    get_service_account_name "$COMPONENTS_TO_CHECK_IRSA_OS" "os"

    echo "[INFO] PostgreSQL Components Service Account Mapping:"
    if ! echo "$PG_SERVICE_ACCOUNTS" | jq .; then
        echo "[ERROR] Failed to parse PostgreSQL service account mapping JSON. Please check the Helm chart values." 1>&2
        exit 1
    fi

    echo "[INFO] OpenSearch Components Service Account Mapping:"
    if ! echo "$OS_SERVICE_ACCOUNTS" | jq .; then
        echo "[ERROR] Failed to parse OpenSearch service account mapping JSON. Please check the Helm chart values." 1>&2
        exit 1
    fi

else
    echo "[FAIL] Cannot retrieve Helm chart values; unable to check service accounts." 1>&2
    exit 1
fi

check_connectivity_with_nmap() {
    component=$1
    target_host=$2
    target_port=$3

    job_name="nmap-connectivity-check-$(echo "$component" | tr '[:upper:]' '[:lower:]')"
    echo "[INFO] Creating job '$job_name' to check connectivity for component=$component to host=$target_host on port=$target_port."

    # Create the Kubernetes job YAML and apply it
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: $job_name
        image: amazonlinux:latest
        command: ["/bin/bash", "-c", "yum install -y nmap && nmap -Pn -p $target_port $target_host"]
      restartPolicy: Never
EOF

    # Check for errors in job creation
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component) Failed to create job $job_name." 1>&2
        SCRIPT_STATUS_OUTPUT=41
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Wait for the job to complete
    wait_command="kubectl wait --for=condition=complete --timeout=60s job/$job_name -n \"$NAMESPACE\""
    echo "[INFO] Running command: $wait_command"
    eval "$wait_command"

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component) Job $job_name did not complete successfully." 1>&2
        kubectl delete job "$job_name" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1
        SCRIPT_STATUS_OUTPUT=42
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Get the output of the job and capture only the result lines
    output=$(kubectl logs job/"$job_name" -n "$NAMESPACE")
    echo "[INFO] nmap output for $component: $output"

    # Delete the job after execution
    delete_command="kubectl delete job \"$job_name\" -n \"$NAMESPACE\" --grace-period=0 --force"
    echo "[INFO] Running command: $delete_command"
    eval "$delete_command"

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[WARN] (component=$component) Failed to delete job $job_name, but it is non-fatal." 1>&2
    fi

    # Check if the port is open based on nmap output
    if echo "$output" | grep -q "open"; then
        echo "[OK] (component=$component) Connectivity check passed: Port $target_port on $target_host is open."
    else
        echo "[FAIL] (component=$component) Connectivity check failed: Port $target_port on $target_host is not open." 1>&2
        SCRIPT_STATUS_OUTPUT=43
        return $SCRIPT_STATUS_OUTPUT
    fi
}

check_irsa_opensearch_requirements() {
    elasticsearch_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.elasticsearch.enabled')
    if [[ -z "$elasticsearch_enabled" || "$elasticsearch_enabled" == "null" ]]; then
        elasticsearch_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.elasticsearch.enabled')
    fi

    opensearch_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.enabled')
    if [[ -z "$opensearch_enabled" || "$opensearch_enabled" == "null" ]]; then
        opensearch_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.opensearch.enabled')
    fi

    opensearch_aws_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.aws.enabled')
    if [[ -z "$opensearch_aws_enabled" || "$opensearch_aws_enabled" == "null" ]]; then
        opensearch_aws_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.opensearch.aws.enabled')
    fi

    # Perform the checks and output messages accordingly
    if [[ "$elasticsearch_enabled" == "true" ]]; then
        echo "[FAIL] IRSA is only supported for OpenSearch. Set global.elasticsearch.enabled to false and use OpenSearch instead." 1>&2
        SCRIPT_STATUS_OUTPUT=51
    fi

    if [[ "$opensearch_enabled" != "true" ]]; then
        echo "[FAIL] OpenSearch must be enabled for IRSA to work. Set global.opensearch.enabled to true." 1>&2
        SCRIPT_STATUS_OUTPUT=51
    fi

    if [[ "$opensearch_aws_enabled" != "true" ]]; then
        echo "[FAIL] OpenSearch AWS integration must be enabled. Set global.opensearch.aws.enabled to true." 1>&2
        SCRIPT_STATUS_OUTPUT=51
    fi

    if [[ "$SCRIPT_STATUS_OUTPUT" -ne 51 ]]; then
        echo "[OK] OpenSearch is correctly configured for IRSA support."
    fi
}

check_opensearch_iam_enabled() {
    opensearch_url=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.url.host')

    if [[ -z "$opensearch_url" || "$opensearch_url" == "null" ]]; then
        echo "[FAIL] The OpenSearch URL is not set. Please ensure that '.global.opensearch.url.host' is correctly specified in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=61
        return
    fi

    echo "[INFO] Retrieved OpenSearch URL: $opensearch_url"

    if $SPAWN_POD; then
        echo "[INFO] Network flow verification for OpenSearch with spawn of pods is enabled (use the -s flag if you want to disable it)."
        check_connectivity_with_nmap "opensearch" "$opensearch_url" "443"
    else
        echo "[INFO] Network flow verification for OpenSearch with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
    fi

    # Parse domain name: remove 'vpc-', extract part up to the last hyphen before the region/service
    domain_name=$(echo "$opensearch_url" | sed -E 's/^vpc-//' | sed -E 's/-[a-z0-9]+(\.[a-z]{2}-[a-z]+-[0-9]+\.es\.amazonaws\.com)$//')
    region=$(echo "$opensearch_url" | sed -E 's/.*\.([a-z]{2}-[a-z]+-[0-9]+)\.es\.amazonaws\.com$/\1/')

    # Verify that both domain name and region were extracted
    if [[ -z "$domain_name" || -z "$region" ]]; then
        echo "[FAIL] Unable to parse the OpenSearch domain name or region from $opensearch_url." 1>&2
        SCRIPT_STATUS_OUTPUT=62
        return
    fi

    echo "[INFO] Parsed OpenSearch domain name: $domain_name in region: $region"

    # Run AWS CLI command to describe the OpenSearch domain in the specified region
    aws_opensearch_describe_cmd="aws opensearch describe-domain --domain-name \"$domain_name\" --region \"$region\""
    echo "[INFO] Running command: ${aws_opensearch_describe_cmd}"
    domain_info=$(eval "$aws_opensearch_describe_cmd")

    # Check if the command was successful
    if [[ $? -ne 0 || -z "$domain_info" ]]; then
        echo "[FAIL] Unable to retrieve OpenSearch domain information for $domain_name in region $region." 1>&2
        SCRIPT_STATUS_OUTPUT=63
        return
    else
        echo "[INFO] Found domain info: $domain_info"
    fi

    advanced_security_enabled=$(echo "$domain_info" | jq -r '.DomainStatus.AdvancedSecurityOptions.Enabled')
    https_enforced=$(echo "$domain_info" | jq -r '.DomainStatus.DomainEndpointOptions.EnforceHTTPS')
    domain_created=$(echo "$domain_info" | jq -r '.DomainStatus.Created')
    domain_deleted=$(echo "$domain_info" | jq -r '.DomainStatus.Deleted')


    if [[ "$advanced_security_enabled" != "true" ]]; then
        echo "[FAIL] Advanced security is not enabled on OpenSearch domain $domain_name." 1>&2
        SCRIPT_STATUS_OUTPUT=64
    else
        echo "[OK] Advanced security is enabled on OpenSearch domain $domain_name."
    fi

    if [[ "$https_enforced" != "true" ]]; then
        echo "[FAIL] HTTPS is not enforced on OpenSearch domain $domain_name." 1>&2
        SCRIPT_STATUS_OUTPUT=65
    else
        echo "[OK] HTTPS is enforced on OpenSearch domain $domain_name."
    fi

    if [[ "$domain_created" != "true" || "$domain_deleted" != "false" ]]; then
        echo "[FAIL] OpenSearch domain $domain_name is either not created or marked as deleted." 1>&2
        SCRIPT_STATUS_OUTPUT=66
    else
        echo "[OK] OpenSearch domain $domain_name is created and not marked as deleted."
    fi

    access_policy=$(echo "$domain_info" | jq -r '.DomainStatus.AccessPolicies')
    if [[ -z "$access_policy" || "$access_policy" == "null" ]]; then
        echo "[FAIL] Cannot retrieve Access Policy for domain $domain_name: $access_policy" 1>&2
        SCRIPT_STATUS_OUTPUT=66
    else
        echo "[INFO] Retrieved Access Policy for domain $domain_name: $access_policy"
    fi

    # Check if the Access Policy allows access (basic check for "Effect": "Allow")
    allow_access=$(echo "$access_policy" | jq -r '.Statement[] | select(.Effect == "Allow")')
    if [[ -n "$allow_access" && "$allow_access" != "null" ]]; then
        echo "[OK] Access policy allows necessary access for domain $domain_name."
    else
        echo "[FAIL] Access policy does not allow access as required for domain $domain_name." 1>&2
        SCRIPT_STATUS_OUTPUT=67
    fi
}

# Call the function if COMPONENTS_TO_CHECK_IRSA_OS is not empty after excluding components
if [[ -n "$COMPONENTS_TO_CHECK_IRSA_OS" ]]; then
    # Use grep -q to check for exclusion
    if ! echo "$COMPONENTS_TO_CHECK_IRSA_OS" | grep -q -F -x -f <(printf '%s\n' "${EXCLUDE_COMPONENTS_ARRAY[@]}"); then
        check_irsa_opensearch_requirements
        check_opensearch_iam_enabled
    fi
fi

check_aurora_cluster() {
    aurora_host="$1"
    aurora_port="$2"
    component="$3"

    # Check if the Aurora URL is set
    if [[ -z "$aurora_host" || "$aurora_host" == "null" ]]; then
        echo "[FAIL] The Aurora host is not set. Please ensure that $component define it correctly in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=71
        return
    fi

    if [[ -z "$aurora_port" || "$aurora_port" == "null" ]]; then
        echo "[FAIL] The Aurora port is not set. Please ensure that $component define it correctly in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=72
        return
    fi

    echo "[INFO] Retrieved Aurora host for $component: $aurora_host:$aurora_port"

    cluster_name=$(echo "$aurora_host" | sed -E 's/^([^.]+)\..*/\1/')
    cluster_id=$(echo "$aurora_host" | sed -E 's/^[^.]+\.(.*)\.[a-z]{2}-[a-z]+-[0-9]+\.rds\.amazonaws\.com/\1/')
    region=$(echo "$aurora_host" | sed -E 's/.*\.([a-z]{2}-[a-z]+-[0-9]+)\.rds\.amazonaws\.com.*/\1/')

    # Verify that both database name and region were extracted
    if [[ -z "$cluster_id" || -z "$region" || -z "$cluster_name" ]]; then
        echo "[FAIL] Unable to parse the Aurora cluster id or name or region from $aurora_host." 1>&2
        SCRIPT_STATUS_OUTPUT=73
        return
    fi

    echo "[INFO] Parsed Aurora database name: $cluster_name in region: $region"

    # Describe DB clusters and check if any match the aurora_cluster_identifier
    aws_rds_describe_cmd="aws rds describe-db-clusters --region \"$region\""
    echo "[INFO] Running command: ${aws_rds_describe_cmd}"
    db_clusters=$(eval "$aws_rds_describe_cmd")
    db_cluster=$(echo "$db_clusters" | jq -e --arg identifier "$cluster_name" '.DBClusters[] | select(.DBClusterIdentifier == $identifier)')

    # Check if the cluster was found
    if [[ -n "$db_cluster" && "$db_cluster" != "null" ]]; then
        echo "[OK] Cluster matching the specified identifier '$cluster_name' found: $db_cluster."
    else
        echo "[FAIL] No matching cluster found for the specified identifier '$cluster_name'." 1>&2
        SCRIPT_STATUS_OUTPUT=74
    fi

    # Extract relevant fields
    iam_enabled=$(echo "$db_cluster" | jq -r '.IAMDatabaseAuthenticationEnabled')
    db_available=$(echo "$db_cluster" | jq -r '.Status')

    # Check if IAM database authentication is enabled
    if [[ "$iam_enabled" != "true" ]]; then
        echo "[FAIL] IAM Database Authentication is not enabled on Aurora DB cluster $cluster_name." 1>&2
        SCRIPT_STATUS_OUTPUT=75
    else
        echo "[OK] IAM Database Authentication is enabled on Aurora DB cluster $cluster_name."
    fi

    # Check if the database instance is created and available
    if [[ "$db_available" != "available" ]]; then
        echo "[FAIL] Aurora DB cluster $cluster_name is not available (status: $db_available)." 1>&2
        SCRIPT_STATUS_OUTPUT=76
    else
        echo "[OK] Aurora DB cluster $cluster_name is created and available."
    fi
}

check_irsa_aurora_requirements() {
    # Filter and loop over components to check while excluding the excluded ones
    for component in $(echo "$COMPONENTS_TO_CHECK_IRSA_PG" | tr ',' ' '); do
        if [[ $component =~ $EXCLUDE_PATTERN ]]; then
            echo "[INFO] Skipping excluded component: $component"
            continue
        fi

        case "$component" in
            "identityKeycloak")
                # Retrieve keycloak_enabled setting from HELM_CHART_VALUES, or fallback to HELM_CHART_DEFAULT_VALUES
                keycloak_enabled=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.postgresql.enabled")

                if [[ "$keycloak_enabled" == "null" ]]; then
                    keycloak_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.postgresql.enabled")
                fi

                if [[ -z "$keycloak_enabled" || "$keycloak_enabled" == "null" ]]; then
                    echo "[FAIL] $component.postgresql.enabled is not defined in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=81
                elif [[ "$keycloak_enabled" != "false" ]]; then
                    echo "[FAIL] $component must have postgresql.enabled set to false in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=82
                else
                    echo "[OK] $component.postgresql.enabled is correctly set to false in your helm values."
                fi

                keycloak_image=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.image // empty")
                if [[ -z "$keycloak_image" || "$keycloak_image" == "null" ]]; then
                    keycloak_image=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.image // empty")
                fi

                if [[ -z "$keycloak_image" || "$keycloak_image" == "null" ]]; then
                    echo "[FAIL] identityKeycloak.image is not defined in both values and default values." 1>&2
                    SCRIPT_STATUS_OUTPUT=83
                else
                    if [[ "$keycloak_image" != *"camunda/keycloak"* ]]; then
                        echo "[FAIL] The identityKeycloak.image must contain 'camunda/keycloak' in its name to support IRSA tooling." 1>&2
                        SCRIPT_STATUS_OUTPUT=84
                    else
                        echo "[OK] identityKeycloak.image is set correctly: $keycloak_image"
                    fi
                fi

                # Retrieve host and port values for identityKeycloak.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_keycloak_host=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.externalDatabase.host // empty")
                if [[ -z "$identity_keycloak_host" || "$identity_keycloak_host" == "null" ]]; then
                    identity_keycloak_host=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.externalDatabase.host // empty")
                fi

                if [[ -z "$identity_keycloak_host" || "$identity_keycloak_host" == "null" ]]; then
                    echo "[FAIL] identityKeycloak.externalDatabase.host is not defined in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=85
                else
                    echo "[INFO] identityKeycloak.externalDatabase.host retrieved from your helm values: $identity_keycloak_host"
                fi

                identity_keycloak_port=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.externalDatabase.port // empty")
                if [[ -z "$identity_keycloak_port" || "$identity_keycloak_port" == "null" ]]; then
                    identity_keycloak_port=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.externalDatabase.port // empty")
                fi

                if [[ -z "$identity_keycloak_port" || "$identity_keycloak_port" == "null" ]]; then
                    identity_keycloak_port=5432
                    echo "[INFO] identityKeycloak.externalDatabase.port is not defined in your helm values. Assuming default port: $identity_keycloak_port"
                else
                    echo "[INFO] identityKeycloak.externalDatabase.port retrieved from your helm values: $identity_keycloak_port"
                fi

                keycloak_external_username=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.user // empty")
                if [[ -z "$keycloak_external_username" || "$keycloak_external_username" == "null" ]]; then
                    keycloak_external_username=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.user // empty")
                fi

                if [[ -z "$keycloak_external_username" || "$keycloak_external_username" == "null" ]]; then
                    echo "[FAIL] $component.externalDatabase.user is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=87
                else
                    echo "[INFO] $component.externalDatabase.user retrieved from your helm values or defaults: $keycloak_external_username"
                fi

                check_aurora_cluster "$identity_keycloak_host" "$identity_keycloak_port" "$component"

                if $SPAWN_POD; then
                    echo "[INFO] Network flow verification for $component with spawn of pods is enabled (use the -s flag if you want to disable it)."
                    check_connectivity_with_nmap "$component" "$identity_keycloak_host" "$identity_keycloak_port"
                else
                    echo "[INFO] Network flow verification for $component with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
                fi

                # Check additional requirements for identityKeycloak
                # Initialize validity flags
                keycloak_extra_args_valid=true
                keycloak_jdbc_params_valid=true
                keycloak_jdbc_driver_valid=true

                # Retrieve values directly from HELM_CHART_VALUES using jq
                keycloak_extra_args=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.extraEnvVars[]? | select(.name == \"KEYCLOAK_EXTRA_ARGS\") | .value // empty")
                if [[ -z "$keycloak_extra_args" || "$keycloak_extra_args" == "null" ]]; then
                    echo "[FAIL] KEYCLOAK_EXTRA_ARGS is not defined." 1>&2
                    keycloak_extra_args_valid=false
                elif [[ ! "$keycloak_extra_args" == *"--db-driver=software.amazon.jdbc.Driver"* ]]; then
                    echo "[FAIL] KEYCLOAK_EXTRA_ARGS must contain '--db-driver=software.amazon.jdbc.Driver'." 1>&2
                    keycloak_extra_args_valid=false
                fi

                keycloak_jdbc_params=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.extraEnvVars[]? | select(.name == \"KEYCLOAK_JDBC_PARAMS\") | .value // empty")
                if [[ -z "$keycloak_jdbc_params" || "$keycloak_jdbc_params" == "null" ]]; then
                    echo "[FAIL] KEYCLOAK_JDBC_PARAMS is not defined." 1>&2
                    keycloak_jdbc_params_valid=false
                elif [[ "$keycloak_jdbc_params" != "wrapperPlugins=iam&ssl=true&sslmode=require" ]]; then
                    echo "[FAIL] KEYCLOAK_JDBC_PARAMS must be 'wrapperPlugins=iam&ssl=true&sslmode=require'." 1>&2
                    keycloak_jdbc_params_valid=false
                fi

                keycloak_jdbc_driver=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.extraEnvVars[]? | select(.name == \"KEYCLOAK_JDBC_DRIVER\") | .value // empty")
                if [[ -z "$keycloak_jdbc_driver" || "$keycloak_jdbc_driver" == "null" ]]; then
                    echo "[FAIL] KEYCLOAK_JDBC_DRIVER is not defined." 1>&2
                    keycloak_jdbc_driver_valid=false
                elif [[ "$keycloak_jdbc_driver" != "aws-wrapper:postgresql" ]]; then
                    echo "[FAIL] KEYCLOAK_JDBC_DRIVER must be 'aws-wrapper:postgresql'." 1>&2
                    keycloak_jdbc_driver_valid=false
                fi

                # Check if all required environment variables are present and valid
                if $keycloak_extra_args_valid && $keycloak_jdbc_params_valid && $keycloak_jdbc_driver_valid; then
                    echo "[OK] Required environment variables for $component are set correctly."
                else
                    echo "[FAIL] One or more required environment variables for $component are not set correctly." 1>&2
                    SCRIPT_STATUS_OUTPUT=87
                fi

                ;;

            "identity")
                # Check if identity.externalDatabase.enabled is defined, with fallback to HELM_CHART_DEFAULT_VALUES
                identity_enabled=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.enabled // empty")
                if [[ -z "$identity_enabled" || "$identity_enabled" == "null" ]]; then
                    # Fallback to HELM_CHART_DEFAULT_VALUES if not defined in HELM_CHART_VALUES
                    identity_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.enabled // empty")
                fi

                if [[ -z "$identity_enabled" || "$identity_enabled" == "null" ]]; then
                    echo "[FAIL] $component.externalDatabase.enabled is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=88
                elif [[ "$identity_enabled" != "true" ]]; then
                    echo "[FAIL] $component.externalDatabase.enabled must be set to true." 1>&2
                    SCRIPT_STATUS_OUTPUT=89
                else
                    echo "[OK] $component.externalDatabase.enabled is correctly set to true."
                fi

                # Retrieve the host for identity.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_external_host=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.host // empty")
                if [[ -z "$identity_external_host" || "$identity_external_host" == "null" ]]; then
                    identity_external_host=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.host // empty")
                fi

                if [[ -z "$identity_external_host" || "$identity_external_host" == "null" ]]; then
                    echo "[FAIL] $component.externalDatabase.host is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=90
                else
                    echo "[INFO] $component.externalDatabase.host retrieved from your helm values or defaults: $identity_external_host"
                fi

                # Retrieve the port for identity.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_external_port=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.port // empty")
                if [[ -z "$identity_external_port" || "$identity_external_port" == "null" ]]; then
                    identity_external_port=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.port // empty")
                fi

                if [[ -z "$identity_external_port" || "$identity_external_port" == "null" ]]; then
                    identity_external_port=5432
                    echo "[INFO] $component.externalDatabase.port is not defined in your helm values. Assuming default port: $identity_external_port"
                else
                    echo "[INFO] $component.externalDatabase.port retrieved from your helm values or defaults: $identity_external_port"
                fi

                identity_external_username=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.username // empty")
                if [[ -z "$identity_external_username" || "$identity_external_username" == "null" ]]; then
                    identity_external_username=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.username // empty")
                fi

                if [[ -z "$identity_external_username" || "$identity_external_username" == "null" ]]; then
                    echo "[FAIL] $component.externalDatabase.username is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=92
                else
                    echo "[INFO] $component.externalDatabase.username retrieved from your helm values or defaults: $identity_external_username"
                fi

                check_aurora_cluster "$identity_external_host" "$identity_external_port" "$component"

                if $SPAWN_POD; then
                    echo "[INFO] Network flow verification for $component with spawn of pods is enabled (use the -s flag if you want to disable it)."
                    check_connectivity_with_nmap "$component" "$identity_external_host" "$identity_external_port"
                else
                    echo "[INFO] Network flow verification for $component with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
                fi

                # Check additional requirements for identity environment variables
                spring_datasource_url=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.env[]? | select(.name == \"SPRING_DATASOURCE_URL\") | .value // empty")
                spring_datasource_driver=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.env[]? | select(.name == \"SPRING_DATASOURCE_DRIVER_CLASS_NAME\") | .value // empty")

                # Initialize validity flags
                spring_datasource_url_valid=true
                spring_datasource_driver_valid=true

                # Validate SPRING_DATASOURCE_URL
                if [[ -z "$spring_datasource_url" || "$spring_datasource_url" == "null" ]]; then
                    echo "[FAIL] SPRING_DATASOURCE_URL for $component is not defined." 1>&2
                    spring_datasource_url_valid=false
                elif [[ ! "$spring_datasource_url" == jdbc:aws-wrapper:postgresql://* || ! "$spring_datasource_url" == *"wrapperPlugins=iam"* ]]; then
                    echo "[FAIL] SPRING_DATASOURCE_URL for $component must start with 'jdbc:aws-wrapper:postgresql://' and contain 'wrapperPlugins=iam'." 1>&2
                    spring_datasource_url_valid=false
                else
                    echo "[OK] SPRING_DATASOURCE_URL for $component is correctly set to '$spring_datasource_url'."
                fi

                # Validate SPRING_DATASOURCE_DRIVER_CLASS_NAME
                if [[ -z "$spring_datasource_driver" || "$spring_datasource_driver" == "null" ]]; then
                    echo "[FAIL] SPRING_DATASOURCE_DRIVER_CLASS_NAME for $component is not defined." 1>&2
                    spring_datasource_driver_valid=false
                elif [[ "$spring_datasource_driver" != "software.amazon.jdbc.Driver" ]]; then
                    echo "[FAIL] SPRING_DATASOURCE_DRIVER_CLASS_NAME for $component must be set to 'software.amazon.jdbc.Driver'." 1>&2
                    spring_datasource_driver_valid=false
                else
                    echo "[OK] SPRING_DATASOURCE_DRIVER_CLASS_NAME for $component is correctly set to '$spring_datasource_driver'."
                fi

                # Check if all required environment variables are present and valid
                if $spring_datasource_url_valid && $spring_datasource_driver_valid; then
                    echo "[OK] All required environment variables for $component are set correctly."
                else
                    echo "[FAIL] One or more required environment variables for $component are not set correctly." 1>&2
                    SCRIPT_STATUS_OUTPUT=93
                fi

                ;;

            "webModeler")
                # Check if webModeler.restapi.externalDatabase.url is defined, with fallback to HELM_CHART_DEFAULT_VALUES
                web_modeler_url=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.externalDatabase.url // empty")
                if [[ -z "$web_modeler_url" || "$web_modeler_url" == "null" ]]; then
                    web_modeler_url=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.restapi.externalDatabase.url // empty")
                fi

                web_modeler_db_host=""
                web_modeler_db_port=""

                if [[ -z "$web_modeler_url" || "$web_modeler_url" == "null" ]]; then
                    echo "[FAIL] $component.restapi.externalDatabase.url is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=94
                else
                    # Regex to capture host and optional port in the required JDBC URL format
                    if [[ "$web_modeler_url" =~ ^jdbc:aws-wrapper:postgresql://([^:/]+)(:[0-9]+)?/[^?]+(\?wrapperPlugins=iam)$ ]]; then
                        web_modeler_db_host="${BASH_REMATCH[1]}"
                        web_modeler_db_port="${BASH_REMATCH[2]:1}"  # Strip the colon from the port, if present

                        echo "[OK] $component.restapi.externalDatabase.url is correctly set: $web_modeler_url"
                        echo "[INFO] Extracted host: $web_modeler_db_host"
                        if [[ -n "$web_modeler_db_port" ]]; then
                            echo "[INFO] $component database extracted port: $web_modeler_db_port"
                        else
                            web_modeler_db_port=5432
                            echo "[INFO] $component database port is not specified in the URL, using default $web_modeler_db_port."
                        fi
                    else
                        echo "[FAIL] $component.restapi.externalDatabase.url must be a valid JDBC URL starting with jdbc:aws-wrapper:postgresql://<host>[:<port>]/<database>?wrapperPlugins=iam for IRSA usage." 1>&2
                        SCRIPT_STATUS_OUTPUT=95
                    fi
                fi

                web_modeler_user=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.externalDatabase.user // empty")
                if [[ -z "$web_modeler_user" || "$web_modeler_user" == "null" ]]; then
                    web_modeler_user=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.restapi.externalDatabase.user // empty")
                fi

                if [[ -z "$web_modeler_user" || "$web_modeler_user" == "null" ]]; then
                    echo "[FAIL] $component.restapi.externalDatabase.user is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=96
                else
                    echo "[OK] $component.restapi.externalDatabase.user is correctly set: $web_modeler_user"
                fi

                check_aurora_cluster "$web_modeler_db_host" "$web_modeler_db_port" "$component"

                if $SPAWN_POD; then
                    echo "[INFO] Network flow verification for $component with spawn of pods is enabled (use the -s flag if you want to disable it)."
                    check_connectivity_with_nmap "$component" "$web_modeler_db_host" "$web_modeler_db_port"
                else
                    echo "[INFO] Network flow verification for $component with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
                fi

                # Retrieve the SPRING_DATASOURCE_DRIVER_CLASS_NAME variable for the component
                spring_datasource_driver_value=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.env[]? | select(.name == \"SPRING_DATASOURCE_DRIVER_CLASS_NAME\") | .value // empty")
                echo "[INFO] Extra env vars for $component: $spring_datasource_driver_value"

                # Check if the variable is set and validate its value
                if [[ -z "$spring_datasource_driver_value" || "$spring_datasource_driver_value" == "null" ]]; then
                    echo "[FAIL] Required environment variable SPRING_DATASOURCE_DRIVER_CLASS_NAME for ${component}.restapi.env is not set." 1>&2
                    SCRIPT_STATUS_OUTPUT=97
                else
                    if [[ "$spring_datasource_driver_value" == "software.amazon.jdbc.Driver" ]]; then
                        echo "[OK] SPRING_DATASOURCE_DRIVER_CLASS_NAME is correctly set to '$spring_datasource_driver_value'."
                    else
                        echo "[FAIL] SPRING_DATASOURCE_DRIVER_CLASS_NAME must be set to 'software.amazon.jdbc.Driver'." 1>&2
                        SCRIPT_STATUS_OUTPUT=98
                    fi
                fi
                ;;

            *)
                echo "[INFO] No checks are defined for component: $component"
                ;;
        esac
    done
}


if [[ -n "$COMPONENTS_TO_CHECK_IRSA_PG" ]]; then
    # Use grep -q to check for exclusion
    if ! echo "$COMPONENTS_TO_CHECK_IRSA_PG" | grep -q -F -x -f <(printf '%s\n' "${EXCLUDE_COMPONENTS_ARRAY[@]}"); then
        check_irsa_aurora_requirements
    fi
fi

 check_service_account_enabled() {
    component="$1"
    service_accounts="$2"

    # Check if {component].serviceAccount.enabled exists in HELM_CHART_VALUES first otherwise, fallback on default
    enabled_value=$(echo "$service_accounts" | jq -r --arg comp "$component" '.[$comp].serviceAccount.enabled')
    if [[ -z "$enabled_value" || "$enabled_value" == "null" ]]; then
        enabled_value=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r --arg comp "$component" '.[$comp].serviceAccount.enabled')
    fi

    # Check if the serviceAccount is disabled
    if [[ "$enabled_value" == "false" ]]; then
        echo "[FAIL] Cannot expect IRSA to work if service account for $component is not enabled ($component.serviceAccount.enabled: false). You can exclude it from the checks using EXCLUDE_COMPONENTS arg." 1>&2
        SCRIPT_STATUS_OUTPUT=101
    else
        echo "[OK] Service account for $component is enabled"
    fi
}

# Function to check if the eks.amazonaws.com/role-arn annotation is present and not empty
check_role_arn_annotation_service_account() {
    service_account_name="$1"
    component_name=$2
    category=$3

    echo "[INFO] Check present of eks.amazonaws.com/role-arn annotation on the serviceAccount $service_account_name"
    kubectl_command="kubectl get serviceaccount \"$service_account_name\" -n \"$NAMESPACE\" -o json"
    echo "[INFO] Running command: $kubectl_command"
    annotations=$(eval "$kubectl_command")
    echo "[INFO] Command output: $annotations"

    role_arn=$(echo "$annotations" | jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"]')

    if [[ -z "$role_arn" || "$role_arn" == "null" ]]; then
        echo "[FAIL] The service account $service_account_name does not have a valid eks.amazonaws.com/role-arn annotation. You must add it in the chart, see https://docs.camunda.io/docs/self-managed/setup/deploy/amazon/amazon-eks/eks-helm/" 1>&2
        SCRIPT_STATUS_OUTPUT=110
    else
        echo "[OK] The service account $service_account_name is bound to the role $role_arn by the eks.amazonaws.com/role-arn annotation."

        # Assign the result to the appropriate category variable
        if [[ "$category" == "pg" ]]; then
            PG_SERVICE_ACCOUNTS=$(echo "$PG_SERVICE_ACCOUNTS" | jq --arg comp "$component_name" --arg arn "$role_arn" '.[$comp].roleArn = $arn')
        elif [[ "$category" == "os" ]]; then
            OS_SERVICE_ACCOUNTS=$(echo "$OS_SERVICE_ACCOUNTS" | jq --arg comp "$component_name" --arg arn "$role_arn" '.[$comp].roleArn = $arn')
        fi
    fi
}


verify_role_arn() {
    role_arn=$1
    role_name=$(basename "$role_arn")
    component=$2
    service_account_name=$3
    echo "[INFO] Verifying role ARN (component=$component,serviceAccount=$service_account_name): $role_arn"

    aws_iam_get_role_cmd="aws iam get-role --role-name \"$role_name\""
    echo "[INFO] Running command: ${aws_iam_get_role_cmd}"
    role_output=$(eval "$aws_iam_get_role_cmd")

    # shellcheck disable=SC2181
    if [ $? -eq 0 ]; then
        echo "[OK] Role ARN $role_arn (component=$component,serviceAccount=$service_account_name) is valid: $role_output"
    else
        echo "[FAIL] Role ARN $role_arn (component=$component,serviceAccount=$service_account_name) is invalid or does not exist." 1>&2
        SCRIPT_STATUS_OUTPUT=120
    fi

    allow_statement=$(echo "$role_output" | jq -r '.Role.AssumeRolePolicyDocument.Statement[] | select(.Effect == "Allow") | select(.Action == "sts:AssumeRoleWithWebIdentity")')

    if [[ -z "$allow_statement" || "$allow_statement" == "null" ]]; then
        echo "[FAIL] Role=$role_arn: AssumeRolePolicyDocument does not contain an Allow statement with Action: sts:AssumeRoleWithWebIdentity." 1>&2
        SCRIPT_STATUS_OUTPUT=121
    else
        echo "[OK] Role=$role_arn: AssumeRolePolicyDocument does contain an Allow statement with Action: sts:AssumeRoleWithWebIdentity."
    fi

    federated_principal=$(echo "$allow_statement" | jq -r '.Principal.Federated')

    if [[ -z "$federated_principal" || "$federated_principal" != arn:aws:iam::*:oidc-provider/oidc.eks.* ]]; then
        echo "[FAIL] Role=$role_arn: No valid Federated Principal found in the Allow statement." 1>&2
        SCRIPT_STATUS_OUTPUT=122
    else
        echo "[OK] Role=$role_arn: Federated Principal found in the Allow statement."
    fi
}

get_aws_identity_from_job() {
    component=$1
    service_account_name=$2
    expected_role_arn=$3

    job_name="aws-identity-check-$(echo "$component" | tr '[:upper:]' '[:lower:]')"

    echo "[INFO] Creating job '$job_name' with service account '$service_account_name' to check AWS identity of component=$component."
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $NAMESPACE
spec:
  template:
    spec:
      serviceAccountName: $service_account_name
      containers:
      - name: $job_name
        image: amazonlinux:latest
        command: ["/bin/bash", "-c", "yum install -y awscli && aws sts get-caller-identity"]
      restartPolicy: Never
EOF

    # Check for errors in job creation
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to create job $job_name." 1>&2
        SCRIPT_STATUS_OUTPUT=130
        return $SCRIPT_STATUS_OUTPUT
    fi


    # Log and execute the wait command
    wait_command="kubectl wait --for=condition=complete --timeout=60s job/$job_name -n \"$NAMESPACE\""
    echo "[INFO] Running command: $wait_command"
    eval "$wait_command"

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Job $job_name did not complete successfully." 1>&2
        kubectl delete job "$job_name" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1
        SCRIPT_STATUS_OUTPUT=131
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Get the output of the job and capture only the JSON part
    output=$(kubectl logs job/"$job_name" -n "$NAMESPACE" | sed -n '/^{/,/}$/p')

    # Log and execute the delete command
    delete_command="kubectl delete job \"$job_name\" -n \"$NAMESPACE\" --grace-period=0 --force"
    echo "[INFO] Running command: $delete_command"
    eval "$delete_command"

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        # non-fatal error
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to delete job $job_name." 1>&2
    fi

    # Check if the output is valid JSON
    echo "$output" | jq .

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Output of aws sts get identity caller job is not valid JSON." 1>&2
        SCRIPT_STATUS_OUTPUT=132
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Extract the ARN from the output
    pod_arn=$(echo "$output" | jq -r '.Arn')
    if [[ -z "$pod_arn" || "$pod_arn" == "null" ]]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to extract ARN from job output." 1>&2
        SCRIPT_STATUS_OUTPUT=133
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Remove the botocore session part from the ARN
    pod_arn_trimmed="${pod_arn%/*}"  # This removes everything after the last slash

    # Strip the ARN prefix for comparison
    pod_arn_cleaned="${pod_arn_trimmed#arn:aws:sts:}"
    pod_arn_cleaned="${pod_arn_cleaned#arn:aws:iam:}"

    modified_expected_role_arn="${expected_role_arn/:role/:assumed-role}"

    # Strip the expected ARN prefix for comparison
    expected_role_cleaned="${modified_expected_role_arn#arn:aws:sts:}"
    expected_role_cleaned="${expected_role_cleaned#arn:aws:iam:}"

    # Ensure that the STS assumed identity matches the expected role
    if [[ "$pod_arn_cleaned" != "$expected_role_cleaned" ]]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Job ARN ($pod_arn_cleaned) does not match expected role ARN ($expected_role_cleaned). IRSA is not working as expected; please verify why the role is not injected." 1>&2
        SCRIPT_STATUS_OUTPUT=134
        return $SCRIPT_STATUS_OUTPUT
    else
        echo "[OK] (component=$component,serviceAccount=$service_account_name) Job ARN ($pod_arn_cleaned) matches expected role ARN ($expected_role_cleaned). IRSA is working as expected."
    fi
}

verify_rds_permissions() {
    role_arn=$1
    role_name=$(basename "$role_arn")
    component=$2
    service_account_name=$3
    echo "[INFO] Verifying RDS permissions for role ARN (component=$component, serviceAccount=$service_account_name): $role_arn"

    # Fetch the role's attached policies
    role_policies_cmd="aws iam list-attached-role-policies --role-name \"$role_name\""
    echo "[INFO] Running command: ${role_policies_cmd}"
    attached_policies=$(eval "$role_policies_cmd")

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] Unable to list attached policies for role ARN $role_arn (component=$component, serviceAccount=$service_account_name)." 1>&2
        SCRIPT_STATUS_OUTPUT=140
        return
    fi

    # Iterate over attached policies and check their permissions
    policy_count=$(echo "$attached_policies" | jq -r '.AttachedPolicies | length')
    echo "[INFO] Found $policy_count attached policies to $role_arn"

    permission_found=false

    for (( i=0; i<policy_count; i++ )); do
        policy_arn=$(echo "$attached_policies" | jq -r ".AttachedPolicies[$i].PolicyArn")
        if [[ -z "$policy_arn" || "$policy_arn" == "null" ]]; then
            echo "[ERROR] policy_arn is either empty or null. Skipping policy check for $role_arn."
            SCRIPT_STATUS_OUTPUT=141
            continue
        fi

        policy_version_id=$(aws iam get-policy --policy-arn "$policy_arn" | jq -r '.Policy.DefaultVersionId')
        if [[ -z "$policy_version_id" || "$policy_version_id" == "null" ]]; then
            echo "[ERROR] policy_version_id is either empty or null. Skipping policy check for $role_arn."
            SCRIPT_STATUS_OUTPUT=141
            continue
        fi

        echo "[INFO] Checking $role_arn attached policy ($policy_arn in version $policy_version_id): $attached_policies"

        # Fetch the policy document
        policy_document_cmd="aws iam get-policy-version --policy-arn \"$policy_arn\" --version-id \"$policy_version_id\""
        echo "[INFO] Running command: ${policy_document_cmd}"
        policy_output=$(eval "$policy_document_cmd")

        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            echo "[FAIL] Unable to retrieve policy document for policy ARN $policy_arn." 1>&2
            SCRIPT_STATUS_OUTPUT=141
            continue
        fi
        echo "[INFO] Checking $policy_arn in version $policy_version_id, PolicyDocument: $policy_output"

        # Check for permissions
        statements=$(echo "$policy_output" | jq -c '.PolicyVersion.Document.Statement[] | select(.Effect == "Allow")')

        # Iterate over each statement correctly
        while IFS= read -r statement; do
            actions=$(echo "$statement" | jq -r '.Action | if type == "array" then join(",") else . end')
            resources=$(echo "$statement" | jq -r '.Resource | if type == "array" then join(",") else . end')

            # Check for permissions
            if [[ "$actions" == *"rds-db:connect"* || "$actions" == *"rds-db:"* ]]; then
                echo "[OK] Role=$role_arn has permission to perform RDS actions: $actions on resources: $resources."
                permission_found=true
                break  2 # break the two loops
            fi
        done <<< "$statements"
    done

    if [ "$permission_found" = false ]; then
        echo "[FAIL] Role=$role_arn does not have permissions to perform 'rds-db:connect' or 'rds-db:*'." 1>&2
        SCRIPT_STATUS_OUTPUT=142
    fi
}

verify_opensearch_permissions() {
    role_arn=$1
    role_name=$(basename "$role_arn")
    component=$2
    service_account_name=$3
    echo "[INFO] Verifying OpenSearch permissions for role ARN (component=$component, serviceAccount=$service_account_name): $role_arn"

    # Fetch the role's attached policies
    role_policies_cmd="aws iam list-attached-role-policies --role-name \"$role_name\""
    echo "[INFO] Running command: ${role_policies_cmd}"
    attached_policies=$(eval "$role_policies_cmd")

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo "[FAIL] Unable to list attached policies for role ARN $role_arn (component=$component, serviceAccount=$service_account_name)." 1>&2
        SCRIPT_STATUS_OUTPUT=150
        return
    fi

    # Iterate over attached policies and check their permissions
    policy_count=$(echo "$attached_policies" | jq -r '.AttachedPolicies | length')
    echo "[INFO] Found $policy_count attached policies to $role_arn"

    permission_found=false

    for (( i=0; i<policy_count; i++ )); do
        policy_arn=$(echo "$attached_policies" | jq -r ".AttachedPolicies[$i].PolicyArn")
        policy_version_id=$(aws iam get-policy --policy-arn "$policy_arn" | jq -r '.Policy.DefaultVersionId')
        echo "[INFO] Checking $role_arn attached policy ($policy_arn in version $policy_version_id): $attached_policies"

        # Fetch the policy document
        policy_document_cmd="aws iam get-policy-version --policy-arn \"$policy_arn\" --version-id \"$policy_version_id\""
        echo "[INFO] Running command: ${policy_document_cmd}"
        policy_output=$(eval "$policy_document_cmd")

        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            echo "[FAIL] Unable to retrieve policy document for policy ARN $policy_arn." 1>&2
            SCRIPT_STATUS_OUTPUT=151
            continue
        fi
        echo "[INFO] Checking $policy_arn in version $policy_version_id, PolicyDocument: $policy_output"

        # Check for permissions
        statements=$(echo "$policy_output" | jq -c '.PolicyVersion.Document.Statement[] | select(.Effect == "Allow")')

        # Iterate over each statement correctly
        while IFS= read -r statement; do
            actions=$(echo "$statement" | jq -r '.Action | if type == "array" then join(",") else . end')
            resources=$(echo "$statement" | jq -r '.Resource | if type == "array" then join(",") else . end')

            # Ensure the resource is not empty
            if [[ -z "$resources" || "$resources" == "null" ]]; then
                continue  # Skip empty resources
            fi

            # Check for OpenSearch permissions
            if [[ "$actions" == *"es:*"* || "$actions" == *"es:ESHttpGet"* ]]; then
                echo "[OK] Role=$role_arn has permission to perform OpenSearch actions: $actions on resources: $resources."
                permission_found=true
                break 2  # Break out of both loops
            fi
        done <<< "$statements"
    done

    if [ "$permission_found" = false ]; then
        echo "[FAIL] Role=$role_arn does not have permissions to perform 'es:*' or 'es:ESHttpGet'." 1>&2
        SCRIPT_STATUS_OUTPUT=152
    fi
}

verify_service_accounts() {
    component=$1
    service_type=$2  # 'pg' or 'os'

    # Check if the service account is enabled for the component
    if [[ "$service_type" == "pg" ]]; then
        check_service_account_enabled "$component" "$PG_SERVICE_ACCOUNTS"

        service_account_name=$(echo "$PG_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].serviceAccountName')
        role_arn=$(echo "$PG_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].roleArn')
    elif [[ "$service_type" == "os" ]]; then
        check_service_account_enabled "$component" "$OS_SERVICE_ACCOUNTS"

        service_account_name=$(echo "$OS_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].serviceAccountName')
        role_arn=$(echo "$OS_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].roleArn')
    else
        echo "[FAIL] Invalid service type '$service_type' provided. Expected 'pg' or 'os'." >&2
        SCRIPT_STATUS_OUTPUT=161
        return
    fi

    if [[ -z "$service_account_name" || "$service_account_name" == "null" ]]; then
        echo "[FAIL] Service account name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=162
        return
    fi

    check_role_arn_annotation_service_account "$service_account_name" "$component" "$service_type"

    if [[ -z "$role_arn" || "$role_arn" == "null" ]]; then
        echo "[FAIL] RoleArn name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=163
        return
    fi

    verify_role_arn "$role_arn" "$component" "$service_account_name"

    # Call the appropriate permission verification function
    if [[ "$service_type" == "pg" ]]; then
        verify_rds_permissions "$role_arn" "$component" "$service_account_name"
    elif [[ "$service_type" == "os" ]]; then
        verify_opensearch_permissions "$role_arn" "$component" "$service_account_name"
    fi

    if $SPAWN_POD; then
        echo "[INFO] IRSA verification with spawn of pods is enabled (use the -s flag if you want to disable it)."
        get_aws_identity_from_job "$component" "$service_account_name" "$role_arn"
    else
        echo "[INFO] IRSA verification with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
    fi
}


# Check PostgreSQL service accounts
for component in $(echo "$PG_SERVICE_ACCOUNTS" | jq -r 'keys[]'); do
    verify_service_accounts "$component" "pg"
done

# Check OpenSearch service accounts
for component in $(echo "$OS_SERVICE_ACCOUNTS" | jq -r 'keys[]'); do
    verify_service_accounts "$component" "os"
done

# IRSA Troubleshooting Guidance
echo ""
echo "Note: If you encounter issues with IRSA, please start by checking the AssumeRole policies for any failing components to ensure they include the necessary permissions for the service accounts."
echo "Additionally, you can utilize our OpenSearch and PostgreSQL client manifests to debug within a pod. These manifests are available at:"
echo "   - OpenSearch Client Manifest: https://github.com/camunda/camunda-tf-eks-module/blob/main/modules/fixtures/opensearch-client.yml"
echo "   - PostgreSQL Client Manifest: https://github.com/camunda/camunda-tf-eks-module/blob/main/modules/fixtures/postgres-client.yml"
echo "If issues persist, we recommend consulting our IRSA Documentation: https://docs.camunda.io/docs/self-managed/setup/deploy/amazon/amazon-eks/irsa/ for additional checks."
echo "This resource provides comprehensive guidance on constructing attached permission policies, setting up trust policies for roles, and implementing Fine-Grained Access Control (FGAC)."
echo "It can help ensure that all necessary configurations are correctly applied."
echo ""

# Check for script failure
if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[FAIL] ${LVL_1_SCRIPT_NAME}: At least one of the checks failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All checks passed."
fi
