# shellcheck shell=bash
#
# Client-side time bound for `kubectl exec` probes.
#
# The connectivity sweep probes every Service from every pod with
# `kubectl exec <pod> -- timeout 2 bash -c '</dev/tcp/host/port'`. That inner
# `timeout` runs inside the container and bounds the probe, not the exec itself.
# When the exec stream wedges -- a node or API-server hiccup, a pod that stops
# servicing new streams -- kubectl blocks with no output and the sweep stalls
# until whatever wall-clock budget the caller happens to have runs out, which
# reports "something went unresponsive" many minutes after the fact and never
# says which probe hung.
#
# Bounding the client side turns that into one named failure in seconds.
#
# Kept free of kubectl so it can be unit-tested without a cluster; the caller
# passes in the timeout binary when it wants to pin one.

# camunda_timeout_binary
#
# Echoes the coreutils timeout binary available on this host, if any. GNU
# coreutils installs it as `timeout`; on macOS with Homebrew coreutils it is
# `gtimeout`. Echoes nothing when neither is present.
camunda_timeout_binary() {
    if command -v timeout >/dev/null 2>&1; then
        printf 'timeout'
    elif command -v gtimeout >/dev/null 2>&1; then
        printf 'gtimeout'
    fi
}

# camunda_exec_bound_prefix <seconds> [timeout-binary]
#
# Echoes the command prefix that bounds an invocation to <seconds>, trailing
# space included so it can be concatenated straight onto a command string.
#
# Echoes nothing when no timeout binary is available, so the caller degrades to
# the previous unbounded behaviour rather than failing outright: a host without
# coreutils still runs the checks, it just loses the bound.
camunda_exec_bound_prefix() {
    local seconds="$1"
    local binary="${2-}"

    [ -n "$binary" ] || binary="$(camunda_timeout_binary)"
    [ -n "$binary" ] || return 0

    printf '%s %s ' "$binary" "$seconds"
}

# camunda_exec_timed_out <status>
#
# Returns 0 when the exit status is the one coreutils `timeout` reports after
# killing the command. Callers must test this *before* interpreting command
# output: a killed exec produces no output at all, and an output-based verdict
# would read that emptiness as success.
camunda_exec_timed_out() {
    [ "${1:-0}" -eq 124 ]
}
