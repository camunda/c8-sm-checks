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
./checks/zeebe/token.sh [-h] [-a AUTH_SERVER_URL] [-i CLIENT_ID] [-s CLIENT_SECRET] [-u TOKEN_AUDIENCE] [-k] [-r CACERT] [-j CLIENTCERT]
```

##### Example:
```bash
./token.sh -a https://local.distro.ultrawombat.com/auth/realms/camunda-platform/protocol/openid-connect/token -i debug -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u zeebe.distro.ultrawombat.com -u zeebe.local.distro.ultrawombat.com
```

##### Options:
- `-h`: Display help message.
- `-a AUTH_SERVER_URL`: Specify the authorization server URL.
- `-i CLIENT_ID`: Specify the client ID.
- `-s CLIENT_SECRET`: Specify the client secret.
- `-u TOKEN_AUDIENCE`: Specify the token audience.
- `-k`: Skip TLS verification (insecure mode).
- `-r CACERT`: Specify the path to the CA certificate file.
- `-j CLIENTCERT`: Specify the path to the client certificate file.

##### Dependencies:
- `curl`: Required for making HTTP requests.

#### gRPC zeebe check (`/checks/zeebe/connectivity.sh`)

##### Description:
This script verifies connectivity to a Zeebe instance using HTTP/2 and gRPC protocols. It also checks the status using `zbctl`.

##### Usage:
```bash
./connectivity.sh [-h] [-H ZEEBE_HOST] [-p ZEEBE_PORT] [-f PROTO_FILE] [-k] [-r CACERT] [-j CLIENTCERT] [-a AUTH_SERVER_URL] [-i CLIENT_ID] [-s CLIENT_SECRET] [-u TOKEN_AUDIENCE]
```

##### Example:
```bash
./checks/zeebe/connectivity.sh -a https://local.distro.ultrawombat.com/auth/realms/camunda-platform/protocol/openid-connect/token -i debug -s 0Rn28VrQxGNxowrCWe6wbujwFghO4990 -u zeebe.distro.ultrawombat.com -H zeebe.local.distro.ultrawombat.com
```

##### Options:
- `-h`: Display help message.
- `-H ZEEBE_HOST`: Specify the Zeebe host.
- `-p ZEEBE_PORT`: Specify the Zeebe port (default: 443).
- `-f PROTO_FILE`: Specify the path to the gateway.proto file or leave empty to download it.
- `-k`: Skip TLS verification (insecure mode).
- `-r CACERT`: Specify the path to the CA certificate file.
- `-j CLIENTCERT`: Specify the path to the client certificate file.
- `-a AUTH_SERVER_URL`: Specify the authorization server URL.
- `-i CLIENT_ID`: Specify the client ID.
- `-s CLIENT_SECRET`: Specify the client secret.
- `-u TOKEN_AUDIENCE`: Specify the token audience.

### Dependencies:
- `curl`: Required for making HTTP requests.
- `grpcurl`: Required for testing gRPC connectivity.
- `zbctl`: Required for checking Zeebe status.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
