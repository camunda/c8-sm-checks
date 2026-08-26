# Tests

## Unit tests

The parts of the checks that are pure value resolution live in `checks/*/lib/` and are covered by
`*.test.sh` scripts next to this file. They need no cluster and run from pre-commit:

```shell
pre-commit run --all-files
./test/kube/aws-irsa-opensearch.test.sh   # or run one directly
```

## Setup a Kind cluster

Setup a kind cluster https://docs.camunda.io/docs/self-managed/setup/deploy/local/local-kubernetes-cluster/.

Then deploy C8 and perform the tests of the scripts against it.
