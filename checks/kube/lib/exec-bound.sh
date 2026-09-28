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

# camunda_exec_duration_valid <duration>
#
# Returns 0 when the duration is one coreutils `timeout` accepts: a number with
# an optional s/m/h/d suffix.
#
# The prefix this library builds is concatenated into a string the caller runs
# through `eval`, and the duration reaches it from the environment. Anything
# unvalidated there is both a silent-failure source and an injection vector:
# `timeout` rejects a bad interval with status 125 and a message matching none
# of the caller's error patterns, which reads as success, and a value such as
# `5 rm -rf /;` would simply be executed.
camunda_exec_duration_valid() {
    case "${1-}" in
        '' | *[!0-9smhd]* | *[smhd]?*) return 1 ;;
        *[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# camunda_exec_bound_prefix <seconds> [timeout-binary]
#
# Echoes the command prefix that bounds an invocation to <seconds>, trailing
# space included so it can be concatenated straight onto a command string.
#
# Echoes nothing when no timeout binary is available, so the caller degrades to
# the previous unbounded behaviour rather than failing outright: a host without
# coreutils still runs the checks, it just loses the bound.
#
# Fails closed on an invalid duration rather than degrading, because that is
# operator error rather than a property of the host.
camunda_exec_bound_prefix() {
    local seconds="$1"
    local binary="${2-}"

    if ! camunda_exec_duration_valid "$seconds"; then
        echo 1>&2 "Error: invalid exec timeout '$seconds'. Expected a number with an optional s/m/h/d suffix, for example 15 or 30s."
        return 2
    fi

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
