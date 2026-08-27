#!/bin/bash

# Unit tests for the OpenSearch IRSA prerequisite resolution
# (checks/kube/lib/aws-irsa-opensearch.sh).
#
# They cover the two value layouts the check has to support: the legacy global
# tree (charts up to 14.x) and the component-scoped one that replaces it in
# chart 15.x, where `global.elasticsearch` and `global.opensearch` are gone.
#
# Usage: ./test/kube/aws-irsa-opensearch.test.sh

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../checks/kube/lib/aws-irsa-opensearch.sh
# shellcheck source-path=SCRIPTDIR
source "$TEST_DIR/../../checks/kube/lib/aws-irsa-opensearch.sh"

command -v jq >/dev/null 2>&1 || { echo 1>&2 "Error: jq is required but not installed. Aborting."; exit 1; }

FAILURES=0

# Chart defaults up to 14.x: the deprecated global database trees are still
# defined alongside the component-scoped ones. Only the keys the check reads are
# reproduced here.
LEGACY_DEFAULTS='{
  "global": {
    "elasticsearch": {"enabled": false},
    "opensearch": {"enabled": false, "aws": {"enabled": false}}
  },
  "orchestration": {
    "data": {"secondaryStorage": {"type": "", "opensearch": {"aws": {"enabled": false}}}},
    "exporters": {"rdbms": {"enabled": false}}
  },
  "optimize": {
    "database": {
      "elasticsearch": {"enabled": false},
      "opensearch": {"enabled": false, "aws": {"enabled": false}}
    }
  }
}'

# Chart 15.x defaults: same tree with global.elasticsearch and global.opensearch
# removed (camunda/camunda-platform-helm#6914).
CHART_15_DEFAULTS='{
  "orchestration": {
    "data": {"secondaryStorage": {"type": "", "opensearch": {"aws": {"enabled": false}}}},
    "exporters": {"rdbms": {"enabled": false}}
  },
  "optimize": {
    "database": {
      "elasticsearch": {"enabled": false},
      "opensearch": {"enabled": false, "aws": {"enabled": false}}
    }
  }
}'

# run_case <name> <components> <defaults> <values> <expected status> [pattern...]
#
# Each pattern must appear in the combined output; a pattern prefixed with "!"
# must not.
run_case() {
    local name="$1" components="$2" defaults="$3" values="$4" expected_status="$5"
    shift 5
    local output status pattern
    local before="$FAILURES"

    output=$( { camunda_resolve_effective_values "$defaults" "$values" \
        && check_irsa_opensearch_requirements "$components" "$CAMUNDA_EFFECTIVE_VALUES" "$CAMUNDA_GLOBAL_DATABASE_VALUES_SUPPORTED"; } 2>&1 )
    status=$?

    if [[ "$status" -ne "$expected_status" ]]; then
        printf '[FAIL] %s: expected exit status %s, got %s\n%s\n' "$name" "$expected_status" "$status" "$output"
        FAILURES=$((FAILURES + 1))
        return
    fi

    for pattern in "$@"; do
        if [[ "$pattern" == "!"* ]]; then
            if grep -qF -- "${pattern#!}" <<< "$output"; then
                printf '[FAIL] %s: output should not contain "%s"\n%s\n' "$name" "${pattern#!}" "$output"
                FAILURES=$((FAILURES + 1))
            fi
        elif ! grep -qF -- "$pattern" <<< "$output"; then
            printf '[FAIL] %s: output should contain "%s"\n%s\n' "$name" "$pattern" "$output"
            FAILURES=$((FAILURES + 1))
        fi
    done

    if [[ "$FAILURES" -eq "$before" ]]; then
        printf '[OK] %s\n' "$name"
    fi
}

# --- Legacy global values (charts up to 14.x) --------------------------------

run_case "legacy: global opensearch with AWS mode passes" \
    "orchestration,optimize" "$LEGACY_DEFAULTS" \
    '{"global": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}' \
    0 \
    "[OK] (component=orchestration)" \
    "[OK] (component=optimize)"

run_case "legacy: elasticsearch selected is rejected" \
    "orchestration,optimize" "$LEGACY_DEFAULTS" \
    '{"global": {"elasticsearch": {"enabled": true}, "opensearch": {"aws": {"enabled": true}}}}' \
    1 \
    "[FAIL] (component=orchestration) IRSA is only supported for OpenSearch" \
    "[FAIL] (component=optimize) IRSA is only supported for OpenSearch"

run_case "legacy: opensearch without AWS mode is rejected and names the global value" \
    "orchestration,optimize" "$LEGACY_DEFAULTS" \
    '{"global": {"opensearch": {"enabled": true}}}' \
    1 \
    "[FAIL] (component=orchestration) OpenSearch AWS integration must be enabled" \
    "global.opensearch.aws.enabled to true"

run_case "legacy: no database configured is rejected" \
    "orchestration,optimize" "$LEGACY_DEFAULTS" '{}' \
    1 \
    "[FAIL] (component=orchestration) OpenSearch must be enabled" \
    "[FAIL] (component=optimize) OpenSearch must be enabled"

# The chart resolves Optimize's database with `optimize.indexPrefix`, which
# tests Elasticsearch before OpenSearch. A deployment that enables both must be
# reported as Elasticsearch, like the chart would use it.
run_case "optimize mirrors the chart's elasticsearch-first precedence" \
    "optimize" "$LEGACY_DEFAULTS" \
    '{
      "global": {"elasticsearch": {"enabled": true}},
      "optimize": {"database": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}
    }' \
    1 \
    "[INFO] (component=optimize) Resolved secondary storage type: elasticsearch" \
    "[FAIL] (component=optimize) IRSA is only supported for OpenSearch"

# --- Component-scoped values (chart 15.x) ------------------------------------

run_case "chart 15: component-scoped opensearch with AWS mode passes" \
    "orchestration,optimize" "$CHART_15_DEFAULTS" \
    '{
      "orchestration": {"data": {"secondaryStorage": {"type": "opensearch", "opensearch": {"aws": {"enabled": true}}}}},
      "optimize": {"database": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}
    }' \
    0 \
    "[OK] (component=orchestration)" \
    "[OK] (component=optimize)" \
    "!Set global.opensearch"

run_case "chart 15: missing AWS mode names the component-scoped values" \
    "orchestration,optimize" "$CHART_15_DEFAULTS" \
    '{
      "orchestration": {"data": {"secondaryStorage": {"type": "opensearch"}}},
      "optimize": {"database": {"opensearch": {"enabled": true}}}
    }' \
    1 \
    "Set orchestration.data.secondaryStorage.opensearch.aws.enabled to true." \
    "Set optimize.database.opensearch.aws.enabled to true." \
    "!global.opensearch.aws.enabled"

run_case "chart 15: elasticsearch selected is rejected" \
    "orchestration,optimize" "$CHART_15_DEFAULTS" \
    '{
      "orchestration": {"data": {"secondaryStorage": {"type": "elasticsearch"}}},
      "optimize": {"database": {"elasticsearch": {"enabled": true}}}
    }' \
    1 \
    '[FAIL] (component=orchestration) IRSA is only supported for OpenSearch, but the deployed values select Elasticsearch. Set orchestration.data.secondaryStorage.type to "opensearch".' \
    "[FAIL] (component=optimize) IRSA is only supported for OpenSearch"

run_case "chart 15: rdbms secondary storage is rejected" \
    "orchestration" "$CHART_15_DEFAULTS" \
    '{"orchestration": {"data": {"secondaryStorage": {"type": "rdbms"}}}}' \
    1 \
    "Resolved secondary storage type: rdbms" \
    "[FAIL] (component=orchestration) OpenSearch must be enabled"

run_case "chart 15: no database configured is rejected" \
    "orchestration,optimize" "$CHART_15_DEFAULTS" '{}' \
    1 \
    "[FAIL] (component=orchestration) OpenSearch must be enabled" \
    "[FAIL] (component=optimize) OpenSearch must be enabled"

run_case "chart 15: global values the chart no longer consumes do not satisfy the check" \
    "orchestration,optimize" "$CHART_15_DEFAULTS" \
    '{"global": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}' \
    1 \
    "[WARN] global.elasticsearch/global.opensearch are set in your values but the deployed chart no longer consumes them" \
    "[FAIL] (component=orchestration) OpenSearch must be enabled" \
    "[FAIL] (component=optimize) OpenSearch must be enabled" \
    "[FAIL] (component=optimize) OpenSearch AWS integration must be enabled"

# --- Component selection ------------------------------------------------------

run_case "only the requested components are verified" \
    "orchestration" "$CHART_15_DEFAULTS" \
    '{"orchestration": {"data": {"secondaryStorage": {"type": "opensearch", "opensearch": {"aws": {"enabled": true}}}}}}' \
    0 \
    "[OK] (component=orchestration)" \
    "!component=optimize"

run_case "an unknown component is skipped" \
    "connectors" "$CHART_15_DEFAULTS" '{}' \
    0 \
    "[INFO] (component=connectors) No OpenSearch prerequisites are defined"

run_case "an empty component list verifies nothing" \
    "" "$CHART_15_DEFAULTS" '{}' 0 \
    "[INFO] No component is being checked for OpenSearch IRSA" \
    "!component="

# --- Value coalescing ---------------------------------------------------------

run_case "deployed values override the chart defaults" \
    "optimize" \
    '{"optimize": {"database": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}}' \
    '{"optimize": {"database": {"opensearch": {"aws": {"enabled": false}}}}}' \
    1 \
    "[FAIL] (component=optimize) OpenSearch AWS integration must be enabled"

run_case "absent deployed values fall back to the chart defaults" \
    "optimize" \
    '{"optimize": {"database": {"opensearch": {"enabled": true, "aws": {"enabled": true}}}}}' \
    "" 0 \
    "[OK] (component=optimize)"

# --- OpenSearch host resolution ----------------------------------------------
#
# The URL check must agree with the prerequisites above on which cluster is
# being verified, so it resolves with the chart's own precedence
# (`camundaPlatform.opensearchHost`): component-scoped first, global last.

# assert_host <name> <defaults> <values> <expected host>
assert_host() {
    local name="$1" defaults="$2" values="$3" expected="$4" actual

    camunda_resolve_effective_values "$defaults" "$values" >/dev/null 2>&1
    actual=$(camunda_opensearch_host "$CAMUNDA_EFFECTIVE_VALUES")

    if [[ "$actual" == "$expected" ]]; then
        printf '[OK] %s\n' "$name"
    else
        printf '[FAIL] %s: expected host "%s", got "%s"\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_host "host: orchestration full URL is stripped to the host" \
    "$CHART_15_DEFAULTS" \
    '{"orchestration": {"data": {"secondaryStorage": {"opensearch": {"url": "https://vpc-os.eu-west-1.es.amazonaws.com:443/path"}}}}}' \
    "vpc-os.eu-west-1.es.amazonaws.com"

assert_host "host: optimize host is used when orchestration has none" \
    "$CHART_15_DEFAULTS" \
    '{"optimize": {"database": {"opensearch": {"url": {"host": "optimize-os.eu-west-1.es.amazonaws.com"}}}}}' \
    "optimize-os.eu-west-1.es.amazonaws.com"

assert_host "host: the component-scoped value wins over the deprecated global one" \
    "$LEGACY_DEFAULTS" \
    '{
      "global": {"opensearch": {"url": {"host": "stale-global.eu-west-1.es.amazonaws.com"}}},
      "optimize": {"database": {"opensearch": {"url": {"host": "real-component.eu-west-1.es.amazonaws.com"}}}}
    }' \
    "real-component.eu-west-1.es.amazonaws.com"

assert_host "host: the deprecated global value is still a fallback on charts that define it" \
    "$LEGACY_DEFAULTS" \
    '{"global": {"opensearch": {"url": {"host": "legacy-global.eu-west-1.es.amazonaws.com"}}}}' \
    "legacy-global.eu-west-1.es.amazonaws.com"

assert_host "host: a global value the chart dropped is ignored" \
    "$CHART_15_DEFAULTS" \
    '{"global": {"opensearch": {"url": {"host": "stale-global.eu-west-1.es.amazonaws.com"}}}}' \
    ""

assert_host "host: nothing configured resolves to empty" \
    "$CHART_15_DEFAULTS" '{}' ""

# The URL check runs even when the merge failed; it must report no host instead
# of tripping over an empty document.
if [[ -n "$(camunda_opensearch_host "")" ]]; then
    printf '[FAIL] host: an unresolved document should yield no host\n'
    FAILURES=$((FAILURES + 1))
else
    printf '[OK] host: an unresolved document yields no host\n'
fi

if [[ "$FAILURES" -ne 0 ]]; then
    printf '\n%s: %s check(s) failed.\n' "$0" "$FAILURES" 1>&2
    exit 1
fi

printf '\n%s: all checks passed.\n' "$0"
