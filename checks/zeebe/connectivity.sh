#!/bin/bash

# Script to verify zeebe connectivity

# Define default variables
ZEEBE_HOST=""
ZEEBE_PORT=""
PROTO_FILE=""
SKIP_TLS_VERIFICATION=""
EXTRA_FLAGS_CURL=""
EXTRA_FLAGS_GRPCURL=""
CACERT=""
CLIENTCERT=""
AUTH_TOKEN=""

# Function to display script usage
usage() {
    echo "Usage: $0 [-h] [-H ZEEBE_HOST] [-p ZEEBE_PORT]"
    echo "Options:"
    echo "  -h                     Display this help message"
    echo "  -H ZEEBE_HOST          Specify the Zeebe host (e.g., zeebe.c8.camunda.langleu.de)"
    echo "  -p ZEEBE_PORT          Specify the Zeebe port (default: 443)"
    echo "  -f PROTO_FILE          Specify the path to gateway.proto file or leave empty to download it"
    echo "  -t AUTH_TOKEN          Specify the auth token to use (optional)"
    echo "  -k                     Skip TLS verification (insecure mode)"
    echo "  -ca CACERT             Specify the path to CA certificate file"
    echo "  -cc CLIENTCERT         Specify the path to Client certificate file"
    exit 1
}

# Parse command line options
while getopts ":hH:p:f:k" opt; do
    case ${opt} in
        h)
            usage
            ;;
        H)
            ZEEBE_HOST=$OPTARG
            ;;
        p)
            ZEEBE_PORT=$OPTARG
            ;;
        f)
            PROTO_FILE=$OPTARG
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

# Check if Zeebe host is provided, if not, prompt user
if [ -z "$ZEEBE_HOST" ]; then
    read -p "Enter Zeebe host: " ZEEBE_HOST
fi

# Check if Zeebe port is provided, if not, use default value
if [ -z "$ZEEBE_PORT" ]; then
    read -p "Enter Zeebe port: " ZEEBE_PORT
fi

if [ "$SKIP_TLS_VERIFICATION" = true ]; then
    EXTRA_FLAGS_CURL="-k"
    EXTRA_FLAGS_GRPCURL="-insecure"
fi

if [ -n "${CACERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cacert ${CACERT} "
    EXTRA_FLAGS_GRPCURL+="-cacert ${CACERT}"
fi

if [ -n "${CLIENTCERT}" ]; then
    EXTRA_FLAGS_CURL+=" -cert ${CLIENTCERT} "
    EXTRA_FLAGS_GRPCURL+=" -cert ${CLIENTCERT} "
fi

# Check if grpcurl is installed
command -v grpcurl >/dev/null 2>&1 || { echo >&2 "grpcurl is required but not installed. Please install it (https://github.com/fullstorydev/grpcurl?tab=readme-ov-file#installation). Aborting."; exit 1; }

# Check if proto file path is provided, if not, download it
if [ -z "$PROTO_FILE" ]; then
    PROTO_FILE="gateway.proto"
    echo "Downloading gateway.proto..."
    wget https://raw.githubusercontent.com/camunda/zeebe/main/zeebe/gateway-protocol/src/main/proto/gateway.proto -O $PROTO_FILE
fi

# Check HTTP/2 connectivity
echo "Checking HTTP/2 connectivity to $ZEEBE_HOST:$ZEEBE_PORT"
curl -v --http2 $EXTRA_FLAGS_CURL https://$ZEEBE_HOST:$ZEEBE_PORT >/dev/null 2>&1 && echo "[OK] HTTP/2 connectivity" || echo "[KO] HTTP/2 connectivity"

# Check gRPC connectivity using grpcurl
echo "Checking gRPC connectivity to $ZEEBE_HOST:$ZEEBE_PORT"
grpcurl -proto $PROTO_FILE $EXTRA_FLAGS_GRPCURL $ZEEBE_HOST:$ZEEBE_PORT gateway_protocol.Gateway/Topology >/dev/null 2>&1 && echo "[OK] gRPC connectivity" || echo "[KO] gRPC connectivity"
