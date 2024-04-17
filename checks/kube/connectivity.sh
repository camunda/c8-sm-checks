#!/bin/bash

# Define default variables
NAMESPACE=""

# Function to display script usage
usage() {
    echo "Usage: $0 [-h] [-n NAMESPACE]"
    echo "Options:"
    echo "  -h                     Display this help message"
    echo "  -n NAMESPACE           Specify the namespace to check"
    exit 1
}

# Parse command line options
while getopts ":hn:" opt; do
    case ${opt} in
        h)
            usage
            ;;
        n)
            NAMESPACE=$OPTARG
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

# Check if namespace is provided
if [ -z "$NAMESPACE" ]; then
    echo "Error: Namespace is not provided." 1>&2
    usage
fi

# Check if kubectl is installed
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is required but not installed. Aborting."; exit 1; }

# Function to check if a service exists in the namespace with specified labels
check_service() {
    local service_name="$1"
    local label_selector="$2"

    if kubectl get service -n "$NAMESPACE" "$service_name" -o jsonpath='{.metadata.labels}' | grep -q "$label_selector"; then
        echo "Service $service_name with labels $label_selector: Found"
    else
        echo "Service $service_name with labels $label_selector: Not Found"
    fi
}

# Function to check if an ingress exists in the namespace with specified annotations
check_ingress() {
    local ingress_name="$1"
    local annotations="$2"

    if kubectl get ingress -n "$NAMESPACE" "$ingress_name" -o jsonpath='{.metadata.annotations}' | grep -q "$annotations"; then
        echo "Ingress $ingress_name with annotations $annotations: Found"
    else
        echo "Ingress $ingress_name with annotations $annotations: Not Found"
    fi
}

# Check services
check_service "identity" "app.kubernetes.io/component=identity,app.kubernetes.io/instance=camunda-platform,app.kubernetes.io/part-of=camunda-platform"
check_service "zeebe" "app.kubernetes.io/component=zeebe,app.kubernetes.io/instance=camunda-platform,app.kubernetes.io/part-of=camunda-platform"
check_service "zeebe-gateway" "app.kubernetes.io/component=zeebe-gateway,app.kubernetes.io/instance=camunda-platform,app.kubernetes.io/part-of=camunda-platform"

# Check ingresses
check_ingress "camunda-ingress" "nginx.ingress.kubernetes.io/ingress.class: nginx"
check_ingress "zeebe-gateway-ingress" "nginx.ingress.kubernetes.io/ingress.class: nginx,nginx.ingress.kubernetes.io/backend-protocol: GRPC,nginx.ingress.kubernetes.io/http2-enable: \"true\""
