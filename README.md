# # C8 Self-Managed Checks

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Overview

This project aims to perform a health check of a Kubernetes installation with Camunda Platform and Zeebe. It provides scripts for verifying connectivity and configuration within the Kubernetes cluster as well as with Zeebe components.

## Table of Contents

- [Directory Structure](#directory-structure)
- [Usage](#usage)
  - [Kubernetes Connectivity](#kubernetes-connectivity)
  - [Zeebe Connectivity](#zeebe-connectivity)
- [License](#license)

The `checks` directory contains scripts for verifying Kubernetes and Zeebe connectivity and configuration. Each script can be executed independently.

## Usage

### Kubernetes Connectivity

The `connectivity.sh` script in the `checks/kube` directory verifies Kubernetes connectivity and configuration. It checks for the presence of services and ingresses that conform to the required specifications.

#### Example Usage:
```bash
./checks/kube/connectivity.sh -n <NAMESPACE>
```

### Zeebe Connectivity

The `connectivity.sh` script in the `checks/zeebe` directory verifies connectivity with Zeebe. It checks gRPC and HTTP/2 connectivity with Zeebe and the Zeebe Gateway, as well as access token generation.

#### Example Usage:
```bash
./checks/zeebe/connectivity.sh -h <ZEEBE_HOST> -p <ZEEBE_PORT> -a <AUTH_SERVER_URL> -i <CLIENT_ID> -s <CLIENT_SECRET> -u <TOKEN_AUDIENCE>
```

For more information on specific options for each script, refer to the help sections within the scripts themselves.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
```

This structure follows common practices seen in many GitHub repositories, providing an overview, table of contents, directory structure, usage instructions, and license information.