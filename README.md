# # C8 Self-Managed Checks

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

## Usage

### Kubernetes

The `connectivity.sh` script in the `checks/kube` directory verifies Kubernetes connectivity and configuration. It checks for the presence of services and ingresses that conform to the required specifications.

#### Example Usage:
```bash
./checks/kube/connectivity.sh -n <NAMESPACE>
```

### Zeebe Connectivity

#### Token generation check (`/checks/zeebe/token.sh`)

##### Description:

This script retrieves an access token from an authorization server using client credentials grant.

##### Usage:
```bash
Usage: ./checks/zeebe/token.sh [-h] [-a AUTH_SERVER_URL] [-i CLIENT_ID] [-s CLIENT_SECRET] [-u TOKEN_AUDIENCE]
Options:
  -h                          Display this help message
  -a AUTH_SERVER_URL          Specify the authorization server URL (e.g.: https://local.distro.ultrawombat.com/auth/realms/camunda-platform/protocol/openid-connect/token)
  -i CLIENT_ID                Specify the client ID
  -s CLIENT_SECRET            Specify the client secret
  -u TOKEN_AUDIENCE           Specify the token audience
  -k                          Skip TLS verification (insecure mode)
  -r CACERT                   Specify the path to CA certificate file
  -j CLIENTCERT               Specify the path to client certificate file
```

##### Example:
```bash
./checks/zeebe/token.sh -a https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/token -i myclientid -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u zeebe.distro.example.com 
```

##### Dependencies:

- `curl`: Required for making HTTP requests.
- A registred [[1] application on C8 Identity](#Reference)

#### gRPC zeebe check (`/checks/zeebe/connectivity.sh`)

##### Description:

This script verifies connectivity to a Zeebe instance using HTTP/2 and gRPC protocols. It also checks the status using `zbctl`.

##### Usage:
```bash
Usage: ./checks/zeebe/connectivity.sh [-h] [-H ZEEBE_HOST]
Options:
  -h                     Display this help message
  -H ZEEBE_HOST          Specify the Zeebe host (e.g., zeebe.c8.camunda.example.com)
  -f PROTO_FILE          Specify the path to gateway.proto file or leave empty to download it
  -k                     Skip TLS verification (insecure mode)
  -r CACERT              Specify the path to CA certificate file
  -j CLIENTCERT          Specify the path to Client certificate file
  -a AUTH_SERVER_URL     Specify the authorization server URL (e.g.: https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/t
oken)
  -i CLIENT_ID           Specify the client ID
  -s CLIENT_SECRET       Specify the client secret
  -u TOKEN_AUDIENCE      Specify the token audience
```

##### Example:
```bash
./checks/zeebe/connectivity.sh -a https://local.distro.example.com/auth/realms/camunda-platform/protocol/openid-connect/token -i myclientid -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u zeebe.distro.example.com -H zeebe.local.distro.example.com:443
```

### Dependencies:

- `curl`: Required for making HTTP requests.
- `grpcurl`: Required for testing gRPC connectivity.
- `zbctl`: Required for checking Zeebe status.
- A registred [[1] application on C8 Identity](#Reference)

## Reference

- [[1] C8: How to register your application on Identity](https://github.com/camunda-community-hub/camunda-8-examples/blob/main/payment-example-process-application/kube/README.md#4-generating-an-m2m-token-for-our-application).

## License


This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
