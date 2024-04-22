#!/bin/bash

set -o pipefail

# Script to verify zeebe connectivity
SCRIPT_NAME=$(basename "$0")
DIR_NAME=$(dirname "$0")
LVL_1_SCRIPT_NAME="$DIR_NAME/$SCRIPT_NAME"

# Define default variables
ZEEBE_HOST=""
PROTO_FILE=""
SKIP_TLS_VERIFICATION=""
EXTRA_FLAGS_CURL=""
EXTRA_FLAGS_GRPCURL=""
EXTRA_FLAGS_ZBCTL=""
EXTRA_FLAGS_TOKEN=""
CACERT=""
CLIENTCERT=""
ZEEBE_AUTHORIZATION_SERVER_URL=""
ZEEBE_CLIENT_ID=""
ZEEBE_CLIENT_SECRET=""
ZEEBE_TOKEN_AUDIENCE=""
ZEEBE_TOKEN_SCOPE="camunda-identity"

# Function to display script usage
usage() {
    echo "Usage: $0 [-h] [-H ZEEBE_HOST]"
    echo "Options:"
    echo "  -h                     Display this help message"
    echo "  -H ZEEBE_HOST          Specify the Zeebe host with the port (e.g., zeebe.c8.camunda.example.com:443)"
    echo "  -f PROTO_FILE          Specify the path to gateway.proto file or leave empty to download it"
    echo "  -k                     Skip TLS verification (insecure mode)"
    echo "  -r CACERT              Specify the path to CA certificate file"
    echo "  -j CLIENTCERT          Specify the path to Client certificate file"
    echo "  -a AUTH_SERVER_URL     Specify the authorization server URL (e.g.: https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/t
oken)"
    echo "  -i CLIENT_ID           Specify the client ID"
    echo "  -s CLIENT_SECRET       Specify the client secret"
    echo "  -u TOKEN_AUDIENCE      Specify the token audience"
    exit 1
}

# Parse command line options
while getopts ":hH:f:kr:j:a:i:s:u:" opt; do
    case ${opt} in
        h)
            usage
            ;;
        H)
            ZEEBE_HOST=$OPTARG
            ;;
        f)
            PROTO_FILE=$OPTARG
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
if [ -z "$ZEEBE_HOST" ]; then
    echo "Error: Missing required options (ZEEBE_HOST)." 1>&2
    usage
fi

# Extract host and port from ZEEBE_HOST
if ! [[ $ZEEBE_HOST =~ ^[^:]+:[0-9]+$ ]]; then
    echo "Error: Invalid format ZEEBE_HOST=$ZEEBE_HOST. Please provide host and port. Aborting." >&2
    exit 1
fi

# pre-check requirements
command -v curl >/dev/null 2>&1 || { echo >&2 "Error: curl is required but not installed. Please install it. Aborting."; exit 1; }
command -v grpcurl >/dev/null 2>&1 || { echo >&2 "Error: grpcurl is required but not installed. Please install it (https://github.com/fullstorydev/grpcurl?tab=readme-ov-file#installation). Aborting."; exit 1; }
command -v zbctl >/dev/null 2>&1 || { echo >&2 "Error: zbctl is required but not installed. Please install it (https://docs.camunda.io/docs/apis-tools/cli-client/). Aborting."; exit 1; }

if [ "$SKIP_TLS_VERIFICATION" = true ]; then
    EXTRA_FLAGS_CURL="-k"
    EXTRA_FLAGS_GRPCURL="-insecure"
    EXTRA_FLAGS_ZBCTL="--insecure"
    EXTRA_FLAGS_TOKEN="-k"
fi

if [ -n "${CACERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cacert \"${CACERT}\" "
    EXTRA_FLAGS_GRPCURL+=" -cacert \"${CACERT}\" "
    EXTRA_FLAGS_ZBCTL+=" --authority \"${CACERT}\" "
    EXTRA_FLAGS_TOKEN+=" -p \"${CACERT}\" "
fi

if [ -n "${CLIENTCERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cert \"${CLIENTCERT}\" "
    EXTRA_FLAGS_GRPCURL+=" -cert \"${CLIENTCERT}\" "
    EXTRA_FLAGS_ZBCTL+=" --certPath \"${CLIENTCERT}\" "
    EXTRA_FLAGS_TOKEN+=" -j \"${CLIENTCERT}\" "
fi

# Check if token is needed
access_token=""
if [ -n "${ZEEBE_AUTHORIZATION_SERVER_URL}" ] || [ -n "${ZEEBE_CLIENT_ID}" ] || [ -n "${ZEEBE_CLIENT_SECRET}" ] || [ -n "${ZEEBE_TOKEN_AUDIENCE}" ]; then
    token_command="${DIR_NAME}/token.sh -a \"${ZEEBE_AUTHORIZATION_SERVER_URL}\" -i \"${ZEEBE_CLIENT_ID}\" -s \"${ZEEBE_CLIENT_SECRET}\" -u \"${ZEEBE_TOKEN_AUDIENCE}\" ${EXTRA_FLAGS_TOKEN}"
    token_output=$(eval "${token_command}")
    access_token=$(echo "$token_output" | sed -n 's/.*Access Token: \(.*\)/\1/p')

    if [ -n "$access_token" ]; then
        echo "[OK] Auth token successfuly generated"
    else
        echo "[KO] Failed to generate access token: $token_output." 1>&2
        SCRIPT_STATUS_OUTPUT=2
    fi
fi

if [ -n "${access_token}" ]; then
    EXTRA_FLAGS_CURL+=" -H 'Authorization: Bearer ${access_token}' "
    EXTRA_FLAGS_GRPCURL+=" -H 'Authorization: Bearer ${access_token}' "
fi


# Check if proto file path is provided, if not, download it
if [ -z "$PROTO_FILE" ]; then
    PROTO_FILE="gateway.proto"
    echo "Downloading gateway.proto..."
    wget https://raw.githubusercontent.com/camunda/zeebe/main/zeebe/gateway-protocol/src/main/proto/gateway.proto -O $PROTO_FILE
fi

# Check HTTP/2 connectivity
check_http2(){
    echo "Checking HTTP/2 connectivity to $ZEEBE_HOST"
    curl_command="curl -so /dev/null --http2 ${EXTRA_FLAGS_CURL} \"https://$ZEEBE_HOST\""
    if eval "${curl_command}"; then
        echo "[OK] HTTP/2 connectivity"
    else
        echo "[KO] HTTP/2 connectivity" 1>&2
        SCRIPT_STATUS_OUTPUT=3
    fi
}

# Check gRPC connectivity using grpcurl
check_grpc(){
    echo "Checking gRPC connectivity to $ZEEBE_HOST"
    grcp_curl_command="grpcurl ${EXTRA_FLAGS_GRPCURL} -proto \"${PROTO_FILE}\" \"${ZEEBE_HOST}\" gateway_protocol.Gateway/Topology"
    if eval "${grcp_curl_command}"; then
        echo "[OK] gRPC connectivity"
    else
        echo "[KO] gRPC connectivity" 1>&2
        SCRIPT_STATUS_OUTPUT=4
    fi
}
check_grpc

# Check zbctl status
check_zbctl() {
    echo "Checking zbctl status to $ZEEBE_HOST..."
    zbctl_command="ZEEBE_TOKEN_SCOPE=${ZEEBE_TOKEN_SCOPE}  zbctl status --address \"${ZEEBE_HOST}\" --authzUrl \"${ZEEBE_AUTHORIZATION_SERVER_URL}\" --clientId \"${ZEEBE_CLIENT_ID}\" --clientSecret \"${ZEEBE_CLIENT_SECRET}\" --audience \"${ZEEBE_TOKEN_AUDIENCE}\" ${EXTRA_FLAGS_ZBCTL}"
    if eval "${zbctl_command}"; then
        echo "[OK] zbctl status"
    else
        echo "[KO] zbctl status" 1>&2
        SCRIPT_STATUS_OUTPUT=5
    fi
}
check_zbctl

# Check if SCRIPT_STATUS_OUTPUT is not equal to zero
if [ "$SCRIPT_STATUS_OUTPUT" -ne 0 ]; then
    echo "[KO] ${LVL_1_SCRIPT_NAME}: At least one of the tests failed (error code: ${SCRIPT_STATUS_OUTPUT})." 1>&2
    exit $SCRIPT_STATUS_OUTPUT
else
    echo "[OK] ${LVL_1_SCRIPT_NAME}: All test passed."
fi
