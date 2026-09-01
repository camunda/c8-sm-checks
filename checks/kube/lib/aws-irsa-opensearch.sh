# shellcheck shell=bash
#
# Resolution of the OpenSearch IRSA prerequisites from the deployed Helm values.
#
# Sourced by checks/kube/aws-irsa.sh. It lives in its own file so the value
# resolution can be exercised without a cluster; see
# test/kube/aws-irsa-opensearch.test.sh.

# jq port of the chart helpers that decide which database a component talks to
# (`orchestration.secondaryStorage` and `optimize.indexPrefix` in
# camunda-platform-helm). Both live here so they stay diffable against the
# chart, and both answer in the chart's own secondary-storage vocabulary rather
# than in a pair of booleans. The component-scoped values win; the deprecated
# global tree is only consulted as a fallback.
CAMUNDA_SECONDARY_STORAGE_JQ='
def orchestration_storage_type:
  if ((.orchestration.data.secondaryStorage.type // "") != "") then
    .orchestration.data.secondaryStorage.type
  elif (.global.noSecondaryStorage // false) then
    "none"
  elif (.orchestration.exporters.rdbms.enabled // false) then
    "rdbms"
  elif ((.global.elasticsearch.enabled // false) or (.optimize.database.elasticsearch.enabled // false)) then
    "elasticsearch"
  elif ((.global.opensearch.enabled // false) or (.optimize.database.opensearch.enabled // false)) then
    "opensearch"
  else
    "unset"
  end;

def optimize_storage_type:
  if ((.global.elasticsearch.enabled // false) or (.optimize.database.elasticsearch.enabled // false)) then
    "elasticsearch"
  elif ((.global.opensearch.enabled // false) or (.optimize.database.opensearch.enabled // false)) then
    "opensearch"
  else
    "unset"
  end;
'

# Whether a set of Helm values still carries the deprecated global database
# trees. Used against the chart defaults to decide support, then against the
# effective values to spot keys the chart would silently ignore.
CAMUNDA_HAS_GLOBAL_DATABASE_VALUES_JQ='((.global.opensearch != null) or (.global.elasticsearch != null))'

# Resolve, once per run, the configuration every OpenSearch check reads. Both
# checks take the result as an argument, so they cannot disagree on which
# database the deployment uses.
#
# $1: chart default values (JSON)
# $2: deployed Helm values (JSON)
#
# Sets CAMUNDA_EFFECTIVE_VALUES and CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED.
CAMUNDA_EFFECTIVE_VALUES=""
CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED=false
# CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED is an output of this library: it is
# read by checks/kube/aws-irsa.sh and by the tests, never within this file.
# shellcheck disable=SC2034
camunda_resolve_effective_values() {
    local defaults="$1" values="$2"

    if [[ -z "$defaults" || "$defaults" == "null" ]]; then
        defaults='{}'
    fi
    if [[ -z "$values" || "$values" == "null" ]]; then
        values='{}'
    fi

    # Coalesce the chart defaults with the deployed values into a single
    # document holding the effective configuration. jq's `*` merges objects
    # recursively with the right-hand side winning, which is how Helm layers
    # user values over the chart defaults.
    if ! CAMUNDA_EFFECTIVE_VALUES=$(jq -n --argjson defaults "$defaults" --argjson values "$values" '$defaults * $values'); then
        echo "[FAIL] Unable to merge the chart default values with the deployed Helm values." 1>&2
        return 1
    fi

    # Chart 15.x deletes `global.elasticsearch` and `global.opensearch` in
    # favour of the component-scoped values. Whether they are still supported is
    # read from the deployed chart's own defaults rather than from its version
    # number, so the check follows the chart through the deprecation window
    # instead of needing a bump on the removal release.
    if [[ "$(jq -r "$CAMUNDA_HAS_GLOBAL_DATABASE_VALUES_JQ" <<< "$defaults")" == "true" ]]; then
        CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED=true
        echo "[INFO] The deployed chart still defines the deprecated global.elasticsearch/global.opensearch values; they are accepted as a fallback for the component-scoped ones."
        return 0
    fi

    CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED=false
    echo "[INFO] The deployed chart does not define the global.elasticsearch/global.opensearch values (removed in chart 15.x); only the component-scoped values are read."

    # The deployed chart ignores these keys, so leaving them in the effective
    # values would let a stale global.opensearch.enabled satisfy a check the
    # chart itself would not honour (false positive).
    if [[ "$(jq -r "$CAMUNDA_HAS_GLOBAL_DATABASE_VALUES_JQ" <<< "$CAMUNDA_EFFECTIVE_VALUES")" == "true" ]]; then
        echo "[WARN] global.elasticsearch/global.opensearch are set in your values but the deployed chart no longer consumes them; they are ignored." 1>&2
        CAMUNDA_EFFECTIVE_VALUES=$(jq 'del(.global.elasticsearch, .global.opensearch)' <<< "$CAMUNDA_EFFECTIVE_VALUES")
    fi
}

# Resolve the OpenSearch host the deployment talks to, with the chart's own
# precedence: the component-scoped values first, the deprecated global tree only
# as a fallback (`camundaPlatform.opensearchHost`). Orchestration carries a full
# URL where Optimize and the global tree carry a bare host, so the scheme, path
# and port are stripped uniformly.
#
# $1: effective values (JSON)
camunda_opensearch_host() {
    local merged="$1"

    # The resolution can be skipped when the values failed to merge; report no
    # host rather than letting jq fail on an empty document.
    if [[ -z "$merged" || "$merged" == "null" ]]; then
        return 0
    fi

    jq -r '
      def host_of: sub("^[a-z]+://"; "") | sub("/.*$"; "") | sub(":[0-9]+$"; "");
      [ .orchestration.data.secondaryStorage.opensearch.url,
        .optimize.database.opensearch.url.host,
        .global.opensearch.url.host ]
      | map(select(type == "string" and . != ""))
      | (first // "")
      | host_of
    ' <<< "$merged"
}

# Verify that every component checked for OpenSearch IRSA is actually backed by
# OpenSearch and configured for AWS authentication. Both the component-scoped
# values and the deprecated global ones are honoured, with the same precedence
# as the chart helpers (`orchestration.secondaryStorage`,
# `optimize.effectiveOsAwsEnabled`).
#
# $1: comma-separated list of components to check
# $2: effective values (JSON), from camunda_resolve_effective_values
# $3: whether the chart still supports the global database values
#
# Returns non-zero when at least one prerequisite is not met.
check_irsa_opensearch_requirements() {
    local components="$1" merged="$2" global_supported="$3"
    local failed=0
    local component component_failed enable_value aws_value
    local storage_type aws_enabled
    local os_component_list=()

    IFS=',' read -r -a os_component_list <<< "$components"
    if [[ "${#os_component_list[@]}" -eq 0 ]]; then
        echo "[INFO] No component is being checked for OpenSearch IRSA; skipping the OpenSearch prerequisites."
        return 0
    fi

    for component in "${os_component_list[@]}"; do
        if [[ -z "$component" ]]; then
            continue
        fi

        case "$component" in
            orchestration)
                storage_type=$(jq -r "${CAMUNDA_SECONDARY_STORAGE_JQ} orchestration_storage_type" <<< "$merged")
                aws_enabled=$(jq -r '((.orchestration.data.secondaryStorage.opensearch.aws.enabled // false) or (.global.opensearch.aws.enabled // false))' <<< "$merged")
                enable_value='orchestration.data.secondaryStorage.type to "opensearch"'
                aws_value="orchestration.data.secondaryStorage.opensearch.aws.enabled to true"
                ;;
            optimize)
                storage_type=$(jq -r "${CAMUNDA_SECONDARY_STORAGE_JQ} optimize_storage_type" <<< "$merged")
                aws_enabled=$(jq -r '((.optimize.database.opensearch.aws.enabled // false) or (.global.opensearch.aws.enabled // false))' <<< "$merged")
                enable_value="optimize.database.opensearch.enabled to true"
                aws_value="optimize.database.opensearch.aws.enabled to true"
                ;;
            *)
                echo "[INFO] (component=$component) No OpenSearch prerequisites are defined for this component, skipping."
                continue
                ;;
        esac

        echo "[INFO] (component=$component) Resolved secondary storage type: $storage_type"

        if [[ "$global_supported" == "true" ]]; then
            enable_value="$enable_value (or the deprecated global.opensearch.enabled to true)"
            aws_value="$aws_value (or the deprecated global.opensearch.aws.enabled to true)"
        fi

        component_failed=0

        case "$storage_type" in
            opensearch)
                ;;
            elasticsearch)
                echo "[FAIL] (component=$component) IRSA is only supported for OpenSearch, but the deployed values select Elasticsearch. Set $enable_value." 1>&2
                component_failed=1
                ;;
            *)
                echo "[FAIL] (component=$component) OpenSearch must be enabled for IRSA to work. Set $enable_value." 1>&2
                component_failed=1
                ;;
        esac

        if [[ "$aws_enabled" != "true" ]]; then
            echo "[FAIL] (component=$component) OpenSearch AWS integration must be enabled. Set $aws_value." 1>&2
            component_failed=1
        fi

        if [[ "$component_failed" -eq 0 ]]; then
            echo "[OK] (component=$component) OpenSearch is correctly configured for IRSA support."
        else
            failed=1
        fi
    done

    return "$failed"
}
