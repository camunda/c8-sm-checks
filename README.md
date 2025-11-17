# C8 Self-Managed Checks

[![Camunda](https://img.shields.io/badge/Camunda-FC5D0D)](https://www.camunda.com/)
[![tests](https://github.com/camunda/c8-sm-checks/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/camunda/c8-sm-checks/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Overview

This project aims to perform a health check of a Kubernetes installation with Camunda Platform and Zeebe. It provides scripts for verifying connectivity and configuration within the Kubernetes cluster as well as with Zeebe components.

## Table of Contents

- [Directory Structure](#directory-structure)
- [Usage](#usage)
  - [Kubernetes](#kubernetes-connectivity)
  - [Zeebe Connectivity](#zeebe-connectivity)
- [License](#license)

The `checks` directory contains scripts for verifying Kubernetes and Zeebe connectivity and configuration. Each script can be executed independently.

**Each script can be executed independently depending on the specific aspect you wish to test.**

## Usage

### Kubernetes


Before using the Kubernetes health check scripts, ensure you have access to Kubernetes with a properly defined `kube config` context pointing to the cluster you wish to debug.

For more information on setting up `kube config` context, refer to the [Kubernetes documentation](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_use-context/).

Additionally, ensure that the AWS CLI is configured and connected to the appropriate tenant for debugging when `awscli` is used.

#### Deployment Check (`/checks/kube/deployment.sh`)

##### Description:

This script checks the status of a Helm deployment in the specified namespace.
It verifies the presence and readiness of required containers within the deployment, depending of your topology you may change required containers.

##### Usage:
```bash
Usage: ./checks/kube/deployment.sh [-h] [-n NAMESPACE] [-d HELM_DEPLOYMENT_NAME]
Options:
  -h                              Display this help message
  -n NAMESPACE                    Specify the namespace to use
  -d HELM_DEPLOYMENT_NAME         Specify the name of the helm deployment (default: camunda)
  -l                              Skip checks of the helm deployment (default: 0)
  -c                              Specify the list of containers to check (comma-separated, default: connector,optimize,orchestration)
```

##### Example:
```bash
./checks/kube/deployment.sh -n camunda-primary -d camunda -c "orchestration,web-modeler"
```

##### Dependencies:

- `kubectl`: Required for interacting with Kubernetes clusters.

### IRSA Configuration Check (`/checks/kube/aws-irsa.sh`)

##### Description:

This script checks the IRSA (IAM Roles for Service Accounts) configuration for AWS Kubernetes. It ensures that the necessary components are configured correctly for OpenSearch and PostgreSQL.

Please note that this check requires Helm to be deployed directly; using `helm template` (e.g., for ArgoCD) is not supported at this time. If you're interested in this feature, feel free to open a ticket.

##### Usage:
```bash
Usage: ./checks/kube/aws-irsa.sh [-h] [-n NAMESPACE] [-e EXCLUDE_COMPONENTS] [-p] [-l] [-s]
Options:
  -h                              Display this help message
  -n NAMESPACE                    Specify the namespace to use (required)
  -e EXCLUDE_COMPONENTS           Comma-separated list of Components to exclude from the check (reference of the component is the root key used in the chart)
  -p                              Comma-separated list of Components to check IRSA for PostgreSQL (overrides default list: identityKeycloak,identity,webModeler)
  -l                              Comma-separated list of Components to check IRSA for OpenSearch (overrides default list: orchestration,optimize)
  -s                              Disable pod spawn for IRSA and connectivity verification.
                                  By default, the script spawns jobs in the specified namespace to perform
                                  IRSA checks and network connectivity tests. These jobs use the amazonlinux:latest
                                  image and scan with nmap to verify connectivity.
```

##### Example:
```bash
./checks/kube/aws-irsa.sh -n camunda-primary -p "identity,webModeler" -l "orchestration"
```

##### Notes:
- The script will display which components are being checked for IRSA support for both PostgreSQL and OpenSearch.
- You can exclude specific components from the checks if necessary.
- By default, the script will spawn debugging pods using the `amazonlinux:latest` container image in the cluster.
- Basic Linux commands such as `sed`, `awk`, and `grep` will also be required for the script's operation.

##### Dependencies:

- `kubectl`: Required for interacting with Kubernetes clusters.
- `aws-cli`: Required for checking AWS-specific configurations.
- `jq`: Required for processing JSON data. [Install jq](https://jqlang.github.io/jq/download/).
- `yq`: Required for processing YAML data. [Install yq](https://mikefarah.gitbook.io/yq/v3.x).
- `helm`: Required for managing Kubernetes applications. [Install helm](https://helm.sh/docs/intro/install/).

#### Connectivity Check (`/checks/kube/connectivity.sh`)

##### Description:

This script verifies Kubernetes connectivity and associated configuration.
It checks for the presence of services and ingresses that conform to the required specifications.

##### Usage:
```bash
Usage: ./checks/kube/connectivity.sh [-h] [-n NAMESPACE]
Options:
  -h                              Display this help message
  -n NAMESPACE                    Specify the namespace to use
  -i                              Skip checks of the ingress class (default: 0)
```

##### Example:
```bash
./checks/kube/connectivity.sh -n camunda-primary
```

##### Dependencies:

- `kubectl`: Required for interacting with Kubernetes clusters.
- `helm`: Required for managing Helm deployments.

### Zeebe Connectivity

#### Token generation check (`/checks/zeebe/token.sh`)

##### Description:

This script retrieves an access token from an authorization server using client credentials grant.

##### Usage:
```bash
Usage: ./checks/zeebe/token.sh [-h] [-a ZEEBE_AUTHORIZATION_SERVER_URL] [-i ZEEBE_CLIENT_ID] [-s ZEEBE_CLIENT_SECRET] [-u ZEEBE_TOKEN_AUDIENCE]
       [-k] [-r CACERT] [-j CLIENTCERT]
Options:
  -h                                  Display this help message
  -a ZEEBE_AUTHORIZATION_SERVER_URL   Specify the authorization server URL (e.g., https://local.distro.ultrawombat.com/auth/realms/camunda-platform/protocol/openid-connect/token)
  -i ZEEBE_CLIENT_ID                  Specify the client ID
  -s ZEEBE_CLIENT_SECRET              Specify the client secret
  -u ZEEBE_TOKEN_AUDIENCE             Specify the token audience
  -k                                  Skip TLS verification (insecure mode)
  -r CACERT                           Specify the path to the CA certificate file
  -j CLIENTCERT                       Specify the path to the client certificate file
```

##### Example:
```bash
./checks/zeebe/token.sh -a https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/token -i myclientid -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u orchestration-api
```

##### Dependencies:

- `curl`: Required for making HTTP requests.
- A registred [[1] application on C8 Identity](#Reference)

#### gRPC zeebe check (`/checks/zeebe/connectivity.sh`)

##### Description:

This script verifies connectivity to a Zeebe Gateway instance using HTTP/2 and gRPC protocols.

##### Usage:
```bash
Usage: ./checks/zeebe/connectivity.sh [-h] [-H ZEEBE_ADDRESS] [-p ZEEBE_VERSION] [-f PROTO_FILE] [-k] [-r CACERT] [-j CLIENTCERT]
       [-a ZEEBE_AUTHORIZATION_SERVER_URL] [-i ZEEBE_CLIENT_ID] [-s ZEEBE_CLIENT_SECRET]
       [-u ZEEBE_TOKEN_AUDIENCE] [-q API_PROTOCOL]
Options:
  -h                                    Display this help message
  -H ZEEBE_ADDRESS                      Specify the Zeebe address and optional port (e.g., zeebe.c8.camunda.example.com:443)
  -p ZEEBE_VERSION                      Specify the Zeebe version (default is the latest version: 8.8 - major.minor only)
  -f PROTO_FILE                         Specify the path to the gateway.proto file or leave empty to download it (default behavior is to download the proto file)
  -k                                    Skip TLS verification (insecure mode)
  -r CACERT                             Specify the path to the CA certificate file
  -j CLIENTCERT                         Specify the path to the client certificate file
  -a ZEEBE_AUTHORIZATION_SERVER_URL     Specify the authorization server URL (e.g., https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/token)
  -i ZEEBE_CLIENT_ID                    Specify the client ID
  -s ZEEBE_CLIENT_SECRET                Specify the client secret
  -u ZEEBE_TOKEN_AUDIENCE               Specify the token audience
  -q API_PROTOCOL                       Specify the API protocol (e.g., http or grpc - default is grpc)
```

##### Example:
```bash
./checks/zeebe/connectivity.sh -a https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/token -i myclientid -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u orchestration-api -H zeebe.local.distro.example.com:443
```

### Dependencies:

- `curl`: Required for making HTTP requests.
- `grpcurl`: Required for testing gRPC connectivity.
- A registred [[1] application on C8 Identity](#Reference)

## Reference

- [[1] C8: How to register your application on Identity](https://github.com/camunda-community-hub/camunda-8-examples/blob/main/payment-example-process-application/kube/README.md#4-generating-an-m2m-token-for-our-application).

## Development Setup

To manage the specific versions of this project, we use the following tools:

- **[asdf](https://asdf-vm.com/)** version manager (see the [installation guide](https://asdf-vm.com/guide/getting-started.html)).
- **[just](https://github.com/casey/just)** as a command runner
  You can install all required plugins:
  ```bash
  just install-tooling
  ```

## License


This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
