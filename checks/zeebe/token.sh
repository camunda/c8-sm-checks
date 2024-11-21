#!/bin/bash

set -o pipefail

# Script to get auth token
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Define default variables
ZEEBE_AUTHORIZATION_SERVER_URL="${ZEEBE_AUTHORIZATION_SERVER_URL:-""}"
ZEEBE_CLIENT_ID="${ZEEBE_CLIENT_ID:-""}"
ZEEBE_CLIENT_SECRET="${ZEEBE_CLIENT_SECRET:-""}"
ZEEBE_TOKEN_AUDIENCE="${ZEEBE_TOKEN_AUDIENCE:-""}"
SKIP_TLS_VERIFICATION=""
CACERT="${CACERT:-""}"
CLIENTCERT="${CLIENTCERT:-""}"
EXTRA_FLAGS_CURL=""

# Function to display script usage
usage() {
    echo "Usage: $0 [-h] [-a AUTH_SERVER_URL] [-i CLIENT_ID] [-s CLIENT_SECRET] [-u TOKEN_AUDIENCE]"
    echo "Options:"
    echo "  -h                                  Display this help message"
    echo "  -a ZEEBE_AUTHORIZATION_SERVER_URL   Specify the authorization server URL (e.g.: https://local.distro.ultrawombat.com/auth/realms/camunda-platform/protocol/openid-connect/t
oken)"
    echo "  -i ZEEBE_CLIENT_ID                  Specify the client ID"
    echo "  -s ZEEBE_CLIENT_SECRET              Specify the client secret"
    echo "  -u ZEEBE_TOKEN_AUDIENCE             Specify the token audience"
    echo "  -k                                  Skip TLS verification (insecure mode)"
    echo "  -r CACERT                           Specify the path to CA certificate file"
    echo "  -j CLIENTCERT                       Specify the path to client certificate file"
    exit 1
}

# Parse command line options
while getopts ":ha:i:s:u:kr:j" opt; do
    case ${opt} in
        h)
            usage
            ;;
        a)
            ZEEBE_AUTHORIZATION_SERVER_URL=$OPTARG
            ;;
        i)
            ZEEBE_CLIENT_ID=$OPTARG
            ;;
        s)
            ZEEBE_CLIENT_SECRET=$OPTARG
            ;;
        u)
            ZEEBE_TOKEN_AUDIENCE=$OPTARG
            ;;
        k)
            SKIP_TLS_VERIFICATION=true
            ;;
        r)
            CACERT="$OPTARG"
            ;;
        j)
            CLIENTCERT="$OPTARG"
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
if [ -z "$ZEEBE_AUTHORIZATION_SERVER_URL" ] || [ -z "$ZEEBE_CLIENT_ID" ] || [ -z "$ZEEBE_CLIENT_SECRET" ] || [ -z "$ZEEBE_TOKEN_AUDIENCE" ]; then
    echo "Error: Missing one of the required options (list of all required options: ZEEBE_AUTHORIZATION_SERVER_URL, ZEEBE_CLIENT_ID, ZEEBE_CLIENT_SECRET, ZEEBE_TOKEN_AUDIENCE)." 1>&2
    usage
fi

if [ "$SKIP_TLS_VERIFICATION" = true ]; then
    EXTRA_FLAGS_CURL="-k"
fi

if [ -n "${CACERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cacert ${CACERT} "
fi

if [ -n "${CLIENTCERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cert ${CLIENTCERT} "
fi

# pre-check requirements
command -v curl >/dev/null 2>&1 || { echo >&2 "Error: curl is required but not installed. Please install it. Aborting."; exit 1; }


curl_command="curl -f -d \"client_id=${ZEEBE_CLIENT_ID}\" -d \"client_secret=${ZEEBE_CLIENT_SECRET}\" -d \"grant_type=client_credentials\" \"${ZEEBE_AUTHORIZATION_SERVER_URL}\" ${EXTRA_FLAGS_CURL}"
echo "[INFO] Running command: ${curl_command}"

# Generate access token
access_token_response=$(eval "${curl_command}")

curl_exit_code=$?

if [ $curl_exit_code -eq 0 ]; then
    echo "[OK] Generated access token"
else
    echo "[FAIL] Curl command failed with exit code $curl_exit_code" 1>&2
    SCRIPT_STATUS_OUTPUT=2
fi

if [ -z "$access_token_response" ]; then
    echo "[FAIL] Failed to generate access token." 1>&2
    SCRIPT_STATUS_OUTPUT=3
fi

# extract the token
  # shellcheck disable=SC2001
token=$(echo "$access_token_response" | sed 's/.*access_token":"\([^"]*\)".*/\1/')
if [ -z "$token" ]; then
    echo "[FAIL] Failed to extract access token." 1>&2
    SCRIPT_STATUS_OUTPUT=4
else
    echo "[OK] Access Token: ${token}"
fi

if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[FAIL] ${LVL_1_SCRIPT_NAME}: At least one of the tests failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All test passed."
fi
