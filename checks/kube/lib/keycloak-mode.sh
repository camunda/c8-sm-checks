# shellcheck shell=bash
#
# Resolution of the Keycloak deployment mode from the deployed Helm values.
#
# Sourced by checks/kube/aws-irsa.sh. It lives in its own file so the
# resolution can be exercised without a cluster; see
# test/kube/keycloak-mode.test.sh.

# camunda_keycloak_subchart_enabled <values_json> <defaults_json>
#
# Echoes "true" when the bundled identityKeycloak subchart is deployed.
#
# `identityKeycloak.enabled` is the signal: the chart documents it as "Internal
# Keycloak: set to true (deploys Keycloak as part of this Helm release)", and
# the key is absent from camunda-platform 8.10, where the subchart was removed,
# so a missing key means "not deployed".
#
# Do NOT key this on `global.identity.keycloak.internal`. That flag only adds an
# ExternalName service for a Keycloak in another namespace, and it defaults to
# false in 8.8, 8.9 and 8.10 alike, so it says nothing about how Keycloak is
# deployed. See camunda/c8-sm-checks#352.
#
# The filter is an explicit if/else rather than `//`, which collapses a boolean
# false into its fallback and would discard the value this decision depends on.
camunda_keycloak_subchart_enabled() {
    local values_json="$1" defaults_json="$2" enabled
    local filter='if .identityKeycloak.enabled == true then "true" else "false" end'

    enabled=$(echo "$values_json" | jq -r "$filter")
    if [[ "$enabled" != "true" ]]; then
        enabled=$(echo "$defaults_json" | jq -r "$filter")
    fi

    echo "$enabled"
}
