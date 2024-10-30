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
SPAWN_POD=true  # By default, the pod will spawn for verification

# List of components from the Helm chart to check for IRSA
# The first list is for components that need IRSA for OpenSearch
COMPONENTS_TO_CHECK_IRSA_OS="zeebe,operate,tasklist,optimize"

# The second list is for components that need IRSA to authenticate to PostgreSQL
COMPONENTS_TO_CHECK_IRSA_PG="identityKeycloak,identity,webModeler"

# Minimum required AWS CLI versions
REQUIRED_AWSCLI_VERSION_V2="2.12.3"
REQUIRED_AWSCLI_VERSION_V1="1.27.160"

# Usage message
usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE] [-e EXCLUDE_COMPONENTS] [-p COMPONENTS_PG] [-l COMPONENTS_OS] [-s]"
    echo "Options:"
    echo "  -h                              Display this help message"
    echo "  -n NAMESPACE                    Specify the namespace to use"
    echo "  -e EXCLUDE_COMPONENTS           Comma-separated list of Components to exclude from the check (reference of the component is the root key used in the chart)"
    echo "  -p COMPONENTS_PG                Comma-separated list of Components to check IRSA for PostgreSQL (overrides default list: $COMPONENTS_TO_CHECK_IRSA_PG)"
    echo "  -l COMPONENTS_OS                Comma-separated list of Components to check IRSA for OpenSearch (overrides default list: $COMPONENTS_TO_CHECK_IRSA_OS)"
    echo "  -s                              Disable pod spawn for IRSA verification"
    exit 1
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
            EXCLUDE_COMPONENTS=$OPTARG
            ;;
        p)
            COMPONENTS_TO_CHECK_IRSA_PG=$OPTARG
            ;;
        l)
            COMPONENTS_TO_CHECK_IRSA_OS=$OPTARG
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
IFS=',' read -r -a EXCLUDE_COMPONENTS_ARRAY <<< "$EXCLUDE_COMPONENTS"
EXCLUDE_PATTERN=$(printf "%s\n" "${EXCLUDE_COMPONENTS_ARRAY[@]}" | sed 's/^/\\b&\\b/' | tr '\n' '|' | sed 's/|$//')

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

    major_version=$(echo "$HELM_CHART_VERSION" | cut -d '.' -f 1)
    if (( major_version < 11 )); then
        echo "[WARNING] This script has only been tested with chart versions 11.x.x and above."
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

check_irsa_opensearch_requirements() {
    elasticsearch_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.elasticsearch.enabled')
    if [[ "$elasticsearch_enabled" == "null" ]]; then
        elasticsearch_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.elasticsearch.enabled')
    fi

    opensearch_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.enabled')
    if [[ "$opensearch_enabled" == "null" ]]; then
        opensearch_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.opensearch.enabled')
    fi

    opensearch_aws_enabled=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.aws.enabled')
    if [[ "$opensearch_aws_enabled" == "null" ]]; then
        opensearch_aws_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r '.global.opensearch.aws.enabled')
    fi

    # Perform the checks and output messages accordingly
    if [[ "$elasticsearch_enabled" == "true" ]]; then
        echo "[FAIL] IRSA is only supported for OpenSearch. Set global.elasticsearch.enabled to false and use OpenSearch instead." 1>&2
        SCRIPT_STATUS_OUTPUT=17
    fi

    if [[ "$opensearch_enabled" != "true" ]]; then
        echo "[FAIL] OpenSearch must be enabled for IRSA to work. Set global.opensearch.enabled to true." 1>&2
        SCRIPT_STATUS_OUTPUT=17
    fi

    if [[ "$opensearch_aws_enabled" != "true" ]]; then
        echo "[FAIL] OpenSearch AWS integration must be enabled. Set global.opensearch.aws.enabled to true." 1>&2
        SCRIPT_STATUS_OUTPUT=17
    fi

    if [[ "$SCRIPT_STATUS_OUTPUT" != 17 ]]; then
        echo "[OK] OpenSearch is correctly configured for IRSA support."
    fi
}

check_opensearch_iam_enabled() {
    opensearch_url=$(echo "$HELM_CHART_VALUES" | jq -r '.global.opensearch.url.host')

    if [[ -z "$opensearch_url" || "$opensearch_url" == "null" ]]; then
        echo "[FAIL] The OpenSearch URL is not set. Please ensure that '.global.opensearch.url.host' is correctly specified in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=18
        return
    fi

    echo "[INFO] Retrieved OpenSearch URL: $opensearch_url"

    # Parse domain name: remove 'vpc-', extract part up to the last hyphen before the region/service
    domain_name=$(echo "$opensearch_url" | sed -E 's/^vpc-//' | sed -E 's/-[a-z0-9]+(\.[a-z]{2}-[a-z]+-[0-9]+\.es\.amazonaws\.com)$//')
    region=$(echo "$opensearch_url" | sed -E 's/.*\.([a-z]{2}-[a-z]+-[0-9]+)\.es\.amazonaws\.com$/\1/')

    # Verify that both domain name and region were extracted
    if [[ -z "$domain_name" || -z "$region" ]]; then
        echo "[FAIL] Unable to parse the OpenSearch domain name or region from $opensearch_url." 1>&2
        SCRIPT_STATUS_OUTPUT=19
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
        SCRIPT_STATUS_OUTPUT=20
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
        SCRIPT_STATUS_OUTPUT=21
    else
        echo "[OK] Advanced security is enabled on OpenSearch domain $domain_name."
    fi

    if [[ "$https_enforced" != "true" ]]; then
        echo "[FAIL] HTTPS is not enforced on OpenSearch domain $domain_name." 1>&2
        SCRIPT_STATUS_OUTPUT=22
    else
        echo "[OK] HTTPS is enforced on OpenSearch domain $domain_name."
    fi

    if [[ "$domain_created" != "true" || "$domain_deleted" != "false" ]]; then
        echo "[FAIL] OpenSearch domain $domain_name is either not created or marked as deleted." 1>&2
        SCRIPT_STATUS_OUTPUT=23
    else
        echo "[OK] OpenSearch domain $domain_name is created and not marked as deleted."
    fi

    access_policy=$(echo "$domain_info" | jq -r '.DomainStatus.AccessPolicies')
    echo "[INFO] Retrieved Access Policy for domain $domain_name: $access_policy"

    # Check if the Access Policy allows access (basic check for "Effect": "Allow")
    allow_access=$(echo "$access_policy" | jq -r '.Statement[] | select(.Effect == "Allow")')
    if [[ -n "$allow_access" ]]; then
        echo "[OK] Access policy allows necessary access for domain $domain_name."
    else
        echo "[FAIL] Access policy does not allow access as required for domain $domain_name." 1>&2
        SCRIPT_STATUS_OUTPUT=24
    fi
}

# Call the function if COMPONENTS_TO_CHECK_IRSA_OS is not empty after excluding components
if [[ -n "$COMPONENTS_TO_CHECK_IRSA_OS" && -n "$(echo "$COMPONENTS_TO_CHECK_IRSA_OS" | grep -v -F -x -f <(echo "$EXCLUDE_COMPONENTS_ARRAY"))" ]]; then
    check_irsa_opensearch_requirements

    check_opensearch_iam_enabled
fi

check_aurora_iam_enabled() {
    aurora_host="$1"
    aurora_port="$2"
    component="$3"

    # Check if the Aurora URL is set
    if [[ -z "$aurora_host" || "$aurora_host" == "null" ]]; then
        echo "[FAIL] The Aurora host is not set. Please ensure that $component define it correctly in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=18
        return
    fi

    if [[ -z "$aurora_port" || "$aurora_port" == "null" ]]; then
        echo "[FAIL] The Aurora port is not set. Please ensure that $component define it correctly in the Helm chart values." 1>&2
        SCRIPT_STATUS_OUTPUT=18
        return
    fi

    echo "[INFO] Retrieved Aurora host for $component: $aurora_host:$aurora_port"

    # Extract database name and region from the URL
    # Assuming the format is similar to jdbc:aws-wrapper:postgresql://<host>:<port>/<database>?wrapperPlugins=iam
    # TODO: modify that
    db_name=$(echo "$aurora_url" | sed -E 's/^jdbc:[^:]+:postgresql:\/\/[^\/]+\/([^?]+).*/\1/')
    region=$(echo "$aurora_url" | grep -oP '[a-z]{2}-[a-z]+-[0-9]+')

    # Verify that both database name and region were extracted
    if [[ -z "$db_name" || -z "$region" ]]; then
        echo "[FAIL] Unable to parse the Aurora database name or region from $aurora_url." 1>&2
        SCRIPT_STATUS_OUTPUT=19
        return
    fi

    echo "[INFO] Parsed Aurora database name: $db_name in region: $region"

    # Run AWS CLI command to describe the Aurora DB cluster in the specified region
    aws_rds_describe_cmd="aws rds describe-db-instances --db-instance-identifier \"$db_name\" --region \"$region\""
    echo "[INFO] Running command: ${aws_rds_describe_cmd}"
    db_info=$(eval "$aws_rds_describe_cmd")

    # Check if the command was successful
    if [[ $? -ne 0 || -z "$db_info" ]]; then
        echo "[FAIL] Unable to retrieve Aurora DB information for $db_name in region $region." 1>&2
        SCRIPT_STATUS_OUTPUT=20
        return
    else
        echo "[INFO] Found DB info: $db_info"
    fi

    # Extract relevant fields
    iam_db_auth_enabled=$(echo "$db_info" | jq -r '.DBInstances[].IAMDatabaseAuthenticationEnabled')
    db_created=$(echo "$db_info" | jq -r '.DBInstances[].DBInstanceStatus')

    # Check if IAM database authentication is enabled
    if [[ "$iam_db_auth_enabled" != "true" ]]; then
        echo "[FAIL] IAM Database Authentication is not enabled on Aurora DB instance $db_name." 1>&2
        SCRIPT_STATUS_OUTPUT=21
    else
        echo "[OK] IAM Database Authentication is enabled on Aurora DB instance $db_name."
    fi

    # Check if the database instance is created and available
    if [[ "$db_created" != "available" ]]; then
        echo "[FAIL] Aurora DB instance $db_name is not available (status: $db_created)." 1>&2
        SCRIPT_STATUS_OUTPUT=22
    else
        echo "[OK] Aurora DB instance $db_name is created and available."
    fi

    access_policy=$(echo "$db_info" | jq -r '.DBInstances[].AccessPolicy')

    # Check if the Access Policy allows access (basic check for "Effect": "Allow")
    allow_access=$(echo "$access_policy" | jq -r '.Statement[] | select(.Effect == "Allow")')
    if [[ -n "$allow_access" ]]; then
         echo "[OK] Access policy allows necessary access for DB instance $db_name."
    else
        echo "[FAIL] Access policy does not allow access as required for DB instance $db_name." 1>&2
         SCRIPT_STATUS_OUTPUT=24
    fi
}

check_irsa_aurora_requirements() {
        # TODO: implement, for each service, check that env and arguments are set correclty (wrapper, etc), for keycloak check that our image is used

    # Filter and loop over components to check while excluding the excluded ones
    for component in $(echo "$COMPONENTS_TO_CHECK_IRSA_PG" | tr ',' ' '); do
        if [[ $component =~ $EXCLUDE_PATTERN ]]; then
            echo "[INFO] Skipping excluded component: $component"
            continue
        fi

        case "$component" in
            "identityKeycloak")
                # Retrieve keycloak_enabled setting from HELM_CHART_VALUES, or fallback to HELM_CHART_DEFAULT_VALUES
                keycloak_enabled=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.postgresql.enabled // empty")

                if [[ -z "$keycloak_enabled" ]]; then
                    # Fallback to HELM_CHART_DEFAULT_VALUES if not defined in HELM_CHART_VALUES
                    keycloak_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.postgresql.enabled // empty")
                fi

                if [[ -z "$keycloak_enabled" ]]; then
                    echo "[FAIL] $component.postgresql.enabled is not defined in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=30
                elif [[ "$keycloak_enabled" != "false" ]]; then
                    echo "[FAIL] $component must have postgresql.enabled set to false in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=31
                else
                    echo "[OK] $component.postgresql.enabled is correctly set to false in your helm values."
                fi

                keycloak_image=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.image // empty")
                if [[ -z "$keycloak_image" ]]; then
                    keycloak_image=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.image // empty")
                fi

                if [[ -z "$keycloak_image" ]]; then
                    echo "[FAIL] identityKeycloak.image is not defined in both values and default values." 1>&2
                    SCRIPT_STATUS_OUTPUT=38
                else
                    if [[ "$keycloak_image" != *"camunda/keycloak"* ]]; then
                        echo "[FAIL] The identityKeycloak.image must contain 'camunda/keycloak' in its name to support IRSA tooling." 1>&2
                        SCRIPT_STATUS_OUTPUT=39
                    else
                        echo "[OK] identityKeycloak.image is set correctly: $keycloak_image"
                    fi
                fi

                # Retrieve host and port values for identityKeycloak.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_keycloak_host=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.externalDatabase.host // empty")
                if [[ -z "$identity_keycloak_host" ]]; then
                    identity_keycloak_host=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.externalDatabase.host // empty")
                fi

                if [[ -z "$identity_keycloak_host" ]]; then
                    echo "[FAIL] identityKeycloak.externalDatabase.host is not defined in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=40
                else
                    echo "[INFO] identityKeycloak.externalDatabase.host retrieved from your helm values: $identity_keycloak_host"
                fi

                identity_keycloak_port=$(echo "$HELM_CHART_VALUES" | jq -r ".identityKeycloak.externalDatabase.port // empty")
                if [[ -z "$identity_keycloak_port" ]]; then
                    identity_keycloak_port=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".identityKeycloak.externalDatabase.port // empty")
                fi

                if [[ -z "$identity_keycloak_port" ]]; then
                    echo "[FAIL] identityKeycloak.externalDatabase.port is not defined in your helm values." 1>&2
                    SCRIPT_STATUS_OUTPUT=41
                else
                    echo "[INFO] identityKeycloak.externalDatabase.port retrieved from your helm values: $identity_keycloak_port"
                fi

                keycloak_external_username=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.user // empty")
                if [[ -z "$keycloak_external_username" ]]; then
                    keycloak_external_username=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.user // empty")
                fi

                if [[ -z "$keycloak_external_username" ]]; then
                    echo "[FAIL] $component.externalDatabase.user is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=41
                else
                    echo "[INFO] $component.externalDatabase.user retrieved from your helm values or defaults: $keycloak_external_username"
                fi

                check_aurora_iam_enabled "$identity_keycloak_host" "$identity_keycloak_port" "$component"

                # TODO: check connectivity to the database

                # Check additional requirements for identityKeycloak
                # Retrieve extra environment variables for the component
                extra_env_vars=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.extraEnvVars[]? | select(.name == \"KEYCLOAK_EXTRA_ARGS\" or .name == \"KEYCLOAK_JDBC_PARAMS\" or .name == \"KEYCLOAK_JDBC_DRIVER\")")

                # Initialize flags for checking individual variables
                keycloak_extra_args_present=false
                keycloak_jdbc_params_present=false
                keycloak_jdbc_driver_present=false

                # Iterate through the extra environment variables and check for the required ones
                if [[ -z "$extra_env_vars" ]]; then
                    echo "[FAIL] Required environment variables for .${component}.extraEnvVars[] are not set correctly: you must define KEYCLOAK_EXTRA_ARGS, KEYCLOAK_JDBC_PARAMS and KEYCLOAK_JDBC_DRIVER with appropriate values." 1>&2
                    SCRIPT_STATUS_OUTPUT=32
                else
                    while IFS= read -r env_var; do
                        var_name=$(echo "$env_var" | jq -r '.name')
                        var_value=$(echo "$env_var" | jq -r '.value')

                        if [[ "$var_name" == "KEYCLOAK_EXTRA_ARGS" ]]; then
                            keycloak_extra_args_present=true
                            # Check if it contains the required db-driver argument
                            if [[ "$var_value" == *"--db-driver=software.amazon.jdbc.Driver"* ]]; then
                                echo "[OK] $var_name is set and contains the required driver argument."
                            else
                                echo "[FAIL] $var_name must include '--db-driver=software.amazon.jdbc.Driver'." 1>&2
                                SCRIPT_STATUS_OUTPUT=33
                            fi
                        elif [[ "$var_name" == "KEYCLOAK_JDBC_PARAMS" ]]; then
                            keycloak_jdbc_params_present=true
                            # Validate the value of KEYCLOAK_JDBC_PARAMS
                            if [[ "$var_value" == *"wrapperPlugins=iam"* ]]; then
                                echo "[OK] $var_name is correctly set to '$var_value'."
                            else
                                echo "[FAIL] $var_name must include 'wrapperPlugins=iam'." 1>&2
                                SCRIPT_STATUS_OUTPUT=34
                            fi
                        elif [[ "$var_name" == "KEYCLOAK_JDBC_DRIVER" ]]; then
                            keycloak_jdbc_driver_present=true
                            # Validate the value of KEYCLOAK_JDBC_DRIVER
                            if [[ "$var_value" == "aws-wrapper:postgresql" ]]; then
                                echo "[OK] $var_name is correctly set to '$var_value'."
                            else
                                echo "[FAIL] $var_name must be set to 'aws-wrapper:postgresql'." 1>&2
                                SCRIPT_STATUS_OUTPUT=35
                            fi
                        fi
                    done <<< "$extra_env_vars"

                    # Check if all required environment variables are present
                    if ! $keycloak_extra_args_present || ! $keycloak_jdbc_params_present || ! $keycloak_jdbc_driver_present; then
                        echo "[FAIL] Some required environment variables for $component are missing (KEYCLOAK_EXTRA_ARGS=$keycloak_extra_args_present, KEYCLOAK_JDBC_PARAMS=$keycloak_jdbc_params_present, KEYCLOAK_JDBC_DRIVER=$keycloak_jdbc_driver_present)." 1>&2
                        SCRIPT_STATUS_OUTPUT=32
                    else
                        echo "[OK] All required environment variables for $component are set."
                    fi
                fi

                ;;

            "identity")
                # Check if identity.externalDatabase.enabled is defined, with fallback to HELM_CHART_DEFAULT_VALUES
                identity_enabled=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.enabled // empty")
                if [[ -z "$identity_enabled" ]]; then
                    # Fallback to HELM_CHART_DEFAULT_VALUES if not defined in HELM_CHART_VALUES
                    identity_enabled=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.enabled // empty")
                fi

                if [[ -z "$identity_enabled" ]]; then
                    echo "[FAIL] $component.externalDatabase.enabled is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=33
                elif [[ "$identity_enabled" != "true" ]]; then
                    echo "[FAIL] $component.externalDatabase.enabled must be set to true." 1>&2
                    SCRIPT_STATUS_OUTPUT=34
                else
                    echo "[OK] $component.externalDatabase.enabled is correctly set to true."
                fi

                # Retrieve the host for identity.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_external_host=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.host // empty")
                if [[ -z "$identity_external_host" ]]; then
                    identity_external_host=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.host // empty")
                fi

                if [[ -z "$identity_external_host" ]]; then
                    echo "[FAIL] $component.externalDatabase.host is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=40
                else
                    echo "[INFO] $component.externalDatabase.host retrieved from your helm values or defaults: $identity_external_host"
                fi

                # Retrieve the port for identity.externalDatabase with fallback to HELM_CHART_DEFAULT_VALUES
                identity_external_port=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.port // empty")
                if [[ -z "$identity_external_port" ]]; then
                    identity_external_port=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.port // empty")
                fi

                if [[ -z "$identity_external_port" ]]; then
                    echo "[FAIL] $component.externalDatabase.port is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=41
                else
                    echo "[INFO] $component.externalDatabase.port retrieved from your helm values or defaults: $identity_external_port"
                fi

                identity_external_username=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.externalDatabase.username // empty")
                if [[ -z "$identity_external_username" ]]; then
                    identity_external_username=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.externalDatabase.username // empty")
                fi

                if [[ -z "$identity_external_username" ]]; then
                    echo "[FAIL] $component.externalDatabase.username is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=41
                else
                    echo "[INFO] $component.externalDatabase.username retrieved from your helm values or defaults: $identity_external_username"
                fi

                check_aurora_iam_enabled "$identity_external_host" "$identity_external_port" "$component"

                # TODO: check connectivity to the database

                # Check additional requirements for identity environment variables
                identity_env_vars=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.env[]? | select(.name == \"SPRING_DATASOURCE_URL\" or .name == \"SPRING_DATASOURCE_DRIVER_CLASS_NAME\")")

                # Initialize flags for checking individual variables
                spring_datasource_url_present=false
                spring_datasource_driver_present=false

                if [[ -z "$identity_env_vars" ]]; then
                    echo "[FAIL] Required environment variables for $component are not set correctly, please define .${component}.env: SPRING_DATASOURCE_URL and SPRING_DATASOURCE_DRIVER_CLASS_NAME." 1>&2
                    SCRIPT_STATUS_OUTPUT=35
                else
                    while IFS= read -r env_var; do
                        var_name=$(echo "$env_var" | jq -r '.name')
                        var_value=$(echo "$env_var" | jq -r '.value')

                        if [[ "$var_name" == "SPRING_DATASOURCE_URL" ]]; then
                            spring_datasource_url_present=true
                            # Validate the value of SPRING_DATASOURCE_URL
                            if [[ "$var_value" == jdbc:aws-wrapper:postgresql://* && "$var_value" == *"wrapperPlugins=iam"* ]]; then
                                echo "[OK] $var_name is correctly set to '$var_value'."
                            else
                                echo "[FAIL] $var_name must start with 'jdbc:aws-wrapper:postgresql://' and contain 'wrapperPlugins=iam'." 1>&2
                                SCRIPT_STATUS_OUTPUT=36
                            fi
                        elif [[ "$var_name" == "SPRING_DATASOURCE_DRIVER_CLASS_NAME" ]]; then
                            spring_datasource_driver_present=true
                            # Validate the value of SPRING_DATASOURCE_DRIVER_CLASS_NAME
                            if [[ "$var_value" == "software.amazon.jdbc.Driver" ]]; then
                                echo "[OK] $var_name is correctly set to '$var_value'."
                            else
                                echo "[FAIL] $var_name must be set to 'software.amazon.jdbc.Driver'." 1>&2
                                SCRIPT_STATUS_OUTPUT=37
                            fi
                        fi
                    done <<< "$identity_env_vars"

                    # Check if all required environment variables are present
                    if ! $spring_datasource_url_present || ! $spring_datasource_driver_present; then
                        echo "[FAIL] Some required environment variables for $component are missing (SPRING_DATASOURCE_URL=$spring_datasource_url_present, SPRING_DATASOURCE_DRIVER_CLASS_NAME=$spring_datasource_driver_present)." 1>&2
                        SCRIPT_STATUS_OUTPUT=35
                    else
                        echo "[OK] All required environment variables for $component are set."
                    fi
                fi

                ;;

            "webModeler")
                # Check if webModeler.restapi.externalDatabase.url is defined, with fallback to HELM_CHART_DEFAULT_VALUES
                web_modeler_url=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.externalDatabase.url // empty")
                if [[ -z "$web_modeler_url" ]]; then
                    web_modeler_url=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.restapi.externalDatabase.url // empty")
                fi

                web_modeler_db_host=""
                web_modeler_db_port=""

                if [[ -z "$web_modeler_url" ]]; then
                    echo "[FAIL] $component.restapi.externalDatabase.url is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=36
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
                        SCRIPT_STATUS_OUTPUT=37
                    fi
                fi

                web_modeler_user=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.externalDatabase.user // empty")
                if [[ -z "$web_modeler_user" ]]; then
                    web_modeler_user=$(echo "$HELM_CHART_DEFAULT_VALUES" | jq -r ".${component}.restapi.externalDatabase.user // empty")
                fi

                if [[ -z "$web_modeler_user" ]]; then
                    echo "[FAIL] $component.restapi.externalDatabase.user is not defined in your helm values or defaults." 1>&2
                    SCRIPT_STATUS_OUTPUT=38
                else
                    echo "[OK] $component.restapi.externalDatabase.user is correctly set: $web_modeler_user"
                fi

                check_aurora_iam_enabled "$web_modeler_db_host" "$web_modeler_db_port" "$component"
                # TODO: check connection

                # Retrieve the SPRING_DATASOURCE_DRIVER_CLASS_NAME variable for the component
                spring_datasource_driver_value=$(echo "$HELM_CHART_VALUES" | jq -r ".${component}.restapi.env[]? | select(.name == \"SPRING_DATASOURCE_DRIVER_CLASS_NAME\") | .value // empty")

                # Check if the variable is set and validate its value
                if [[ -z "$spring_datasource_driver_value" ]]; then
                    echo "[FAIL] Required environment variable SPRING_DATASOURCE_DRIVER_CLASS_NAME for ${component}.restapi.env is not set." 1>&2
                    SCRIPT_STATUS_OUTPUT=36
                else
                    if [[ "$spring_datasource_driver_value" == "software.amazon.jdbc.Driver" ]]; then
                        echo "[OK] SPRING_DATASOURCE_DRIVER_CLASS_NAME is correctly set to '$spring_datasource_driver_value'."
                    else
                        echo "[FAIL] SPRING_DATASOURCE_DRIVER_CLASS_NAME must be set to 'software.amazon.jdbc.Driver'." 1>&2
                        SCRIPT_STATUS_OUTPUT=37
                    fi
                fi
                ;;

            *)
                echo "[INFO] No checks are defined for component: $component"
                ;;
        esac
    done
}

if [[ -n "$COMPONENTS_TO_CHECK_IRSA_PG" && -n "$(echo "$COMPONENTS_TO_CHECK_IRSA_PG" | grep -v -F -x -f <(echo "$EXCLUDE_COMPONENTS_ARRAY"))" ]]; then
    check_irsa_aurora_requirements

    check_aurora_iam_enabled
    exit 80
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

    if [ $? -eq 0 ]; then
        echo "[OK] Role ARN $role_arn (component=$component,serviceAccount=$service_account_name) is valid: $role_output"
    else
        echo "[FAIL] Role ARN $role_arn (component=$component,serviceAccount=$service_account_name) is invalid or does not exist." 1>&2
        SCRIPT_STATUS_OUTPUT=9
    fi

    allow_statement=$(echo "$role_output" | jq -r '.Role.AssumeRolePolicyDocument.Statement[] | select(.Effect == "Allow") | select(.Action == "sts:AssumeRoleWithWebIdentity")')

    if [ -z "$allow_statement" ]; then
        echo "[FAIL] Role=$role_arn: AssumeRolePolicyDocument does not contain an Allow statement with Action: sts:AssumeRoleWithWebIdentity." 1>&2
        SCRIPT_STATUS_OUTPUT=11
    else
        echo "[OK] Role=$role_arn: AssumeRolePolicyDocument does contain an Allow statement with Action: sts:AssumeRoleWithWebIdentity."
    fi

    federated_principal=$(echo "$allow_statement" | jq -r '.Principal.Federated')

    if [[ -z "$federated_principal" || "$federated_principal" != arn:aws:iam::*:oidc-provider/oidc.eks.* ]]; then
        echo "[FAIL] Role=$role_arn: No valid Federated Principal found in the Allow statement." 1>&2
        SCRIPT_STATUS_OUTPUT=12
    else
        echo "[OK] Role=$role_arn: Federated Principal found in the Allow statement."
    fi
}

get_aws_identity_from_job() {
    component=$1
    service_account_name=$2
    expected_role_arn=$3

    job_name="aws-identity-check-${component}"

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
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to create job $job_name." 1>&2
        SCRIPT_STATUS_OUTPUT=13
        return $SCRIPT_STATUS_OUTPUT
    fi


    # Log and execute the wait command
    local wait_command="kubectl wait --for=condition=complete --timeout=60s job/$job_name -n \"$NAMESPACE\""
    echo "[INFO] Running command: $wait_command"
    eval "$wait_command"
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Job $job_name did not complete successfully." 1>&2
        kubectl delete job "$job_name" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1
        SCRIPT_STATUS_OUTPUT=13
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Get the output of the job and capture only the JSON part
    output=$(kubectl logs job/"$job_name" -n "$NAMESPACE" | sed -n '/^{/,/}$/p')

    # Log and execute the delete command
    delete_command="kubectl delete job \"$job_name\" -n \"$NAMESPACE\" --grace-period=0 --force"
    echo "[INFO] Running command: $delete_command"
    eval "$delete_command"
    if [ $? -ne 0 ]; then
        # non-fatal error
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to delete job $job_name." 1>&2
    fi

    # Check if the output is valid JSON
    echo "$output" | jq .
    if [ $? -ne 0 ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Output of aws sts get identity caller job is not valid JSON." 1>&2
        SCRIPT_STATUS_OUTPUT=13
        return $SCRIPT_STATUS_OUTPUT
    fi

    # Extract the ARN from the output
    pod_arn=$(echo "$output" | jq -r '.Arn')
    if [ -z "$pod_arn" ]; then
        echo "[FAIL] (component=$component,serviceAccount=$service_account_name) Failed to extract ARN from job output." 1>&2
        SCRIPT_STATUS_OUTPUT=13
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
        SCRIPT_STATUS_OUTPUT=13
        return $SCRIPT_STATUS_OUTPUT
    else
        echo "[OK] (component=$component,serviceAccount=$service_account_name) Job ARN ($pod_arn_cleaned) matches expected role ARN ($expected_role_cleaned). IRSA is working as expected."
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

    role_arn=$(echo "$PG_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].roleArn')
    if [[ -z "$role_arn" ]]; then
        echo "[FAIL] RoleArn name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=10
        continue
    fi

    verify_role_arn "$role_arn" "$component" "$service_account_name"

    if $SPAWN_POD; then
        echo "[INFO] IRSA verification with spawn of pods is enabled (use the -s flag if you want to disable it)."
        get_aws_identity_from_job "$component" "$service_account_name" "$role_arn"
    else
        echo "[INFO] IRSA verification with spawn of pods is disabled (-s flag). No pods will be spawned for component verification."
    fi

    exit 3
done

# Check OpenSearch service accounts are enabled
for component in $(echo "$OS_SERVICE_ACCOUNTS" | jq -r 'keys[]'); do
    check_service_account_enabled "$component" "$OS_SERVICE_ACCOUNTS"

    service_account_name=$(echo "$OS_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].serviceAccountName')
    if [[ -z "$service_account_name" ]]; then
        echo "[FAIL] Service account name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=8
        continue
    fi

    check_role_arn_annotation_service_account "$service_account_name" "$component" "os"

    role_arn=$(echo "$OS_SERVICE_ACCOUNTS" | jq -r --arg comp "$component" '.[$comp].roleArn')
    if [[ -z "$role_arn" ]]; then
        echo "[FAIL] RoleArn name for component '$component' is empty. Skipping verification." 1>&2
        SCRIPT_STATUS_OUTPUT=10
        continue
    fi

    verify_role_arn "$role_arn" "$component" "$service_account_name"
done


exit 6


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
# At the end, if not match, indicates that it may be necessary to check each AssumeRolePolicy for the component that fails


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
