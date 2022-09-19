#!/usr/bin/env bats

set -o pipefail

CLIENT_NAME="kubectl"


set -o pipefail

# Check for Namespaces
@test "Verify - kube-cleanupper namespace exists" {
	run $CLIENT_NAME get ns kube-cleanupper
	[ "$status" -eq 0 ]
}


@test "Verify - Conrjob kube-cleanupper exists" {
	run $CLIENT_NAME get cronjob -n kube-cleanupper
	[ "$status" -eq 0 ]
}
