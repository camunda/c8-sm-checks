#!/bin/bash

# Define default variables
ZEEBE_AUTHORIZATION_SERVER_URL=""
ZEEBE_CLIENT_ID=""
ZEEBE_CLIENT_SECRET=""
ZEEBE_TOKEN_AUDIENCE=""
SKIP_TLS_VERIFICATION=""
CACERT=""
CLIENTCERT=""
EXTRA_FLAGS_CURL=""

# Function to display script usage
usage() {
    echo "Usage: $0 [-h] [-a AUTH_SERVER_URL] [-i CLIENT_ID] [-s CLIENT_SECRET] [-u TOKEN_AUDIENCE]"
    echo "Options:"
    echo "  -h                          Display this help message"
    echo "  -a AUTH_SERVER_URL          Specify the authorization server URL"
    echo "  -i CLIENT_ID                Specify the client ID"
    echo "  -s CLIENT_SECRET            Specify the client secret"
    echo "  -u TOKEN_AUDIENCE           Specify the token audience"
    echo "  -k                          Skip TLS verification (insecure mode)"
    echo "  -ca CA_CERT                  Specify the path to CA certificate file"
    echo "  -cc CLIENT_CERT             Specify the path to client certificate file"
    exit 1
}

# Parse command line options
while getopts ":ha:i:s:u:k" opt; do
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
        ca)
            CACERT="$OPTARG"
            ;;
        cc)
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

# Check if all required options are provided
if [ -z "$ZEEBE_AUTHORIZATION_SERVER_URL" ] || [ -z "$ZEEBE_CLIENT_ID" ] || [ -z "$ZEEBE_CLIENT_SECRET" ] || [ -z "$ZEEBE_TOKEN_AUDIENCE" ]; then
    echo "Error: Missing required options." 1>&2
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

# Generate access token
ACCESS_TOKEN=$(curl -s --request POST \
  --url $ZEEBE_AUTHORIZATION_SERVER_URL $EXTRA_FLAGS_CURL \
  --header 'content-type: application/json' \
  --data "{\"client_id\":\"$ZEEBE_CLIENT_ID\",\"client_secret\":\"$ZEEBE_CLIENT_SECRET\",\"audience\":\"$ZEEBE_TOKEN_AUDIENCE\",\"grant_type\":\"client_credentials\"}" | sed 's/.*access_token":"\([^"]*\)".*/\1/' )

# Check if access token is empty
if [ -z "$ACCESS_TOKEN" ]; then
    echo "[KO] Failed to generate access token." 1>&2
    exit 1
fi

echo "[OK] Access Token: $ACCESS_TOKEN"