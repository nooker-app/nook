#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--xctrace TEMPLATE] [--only ID[,ID...]] <label> <lib-name-or-path> <script.json> [variant]" >&2
  exit 2
}

xctrace_template=""
only=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --xctrace) [[ $# -ge 2 ]] || usage; xctrace_template="$2"; shift 2 ;;
    --only) [[ $# -ge 2 ]] || usage; only="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ $# -ge 3 && $# -le 4 ]] || usage
[[ -z "$only" || "$only" =~ ^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$ ]] || { echo "invalid --only (step ids, comma-separated): $only" >&2; exit 2; }

label="$1"
lib_arg="$2"
script_arg="$3"
variant="${4:-none}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
# `make perf-build` (-O, DEBUG instrumentation kept). NOOK_PERF_APP points
# elsewhere, but that build must also carry a current perf-build stamp.
app="${NOOK_PERF_APP:-$repo_root/DerivedData-perf/Build/Products/Debug/Nook.app}"
executable="$app/Contents/MacOS/Nook"
port=8765
library_timeout="${NOOK_PERF_LIBRARY_TIMEOUT_SECONDS:-60}"
case "$(basename "$script_arg")" in refresh*) default_cap=300 ;; *) default_cap=600 ;; esac
run_timeout="${NOOK_PERF_RUN_TIMEOUT_SECONDS:-$default_cap}"
for limit in "$library_timeout" "$run_timeout"; do
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "timeouts must be positive integer seconds" >&2; exit 2; }
done

# The label becomes a path under perf-runs/ that rsync --delete writes into.
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid label (use [A-Za-z0-9._-], no leading dot): $label" >&2; exit 2; }
case "$variant" in none | trickle | burst | big1) ;; *) echo "unknown feed variant: $variant" >&2; exit 2 ;; esac

if [[ -d "$lib_arg" ]]; then
  golden="$(cd "$lib_arg" && pwd -P)"
else
  golden="$repo_root/perf-data/golden/$lib_arg"
fi
[[ -d "$golden" ]] || { echo "golden library not found: $golden" >&2; exit 1; }
[[ -f "$script_arg" ]] || { echo "scenario script not found: $script_arg" >&2; exit 1; }
[[ -x "$executable" ]] || { echo "perf app not found: $app (run make perf-build first)" >&2; exit 1; }
# Never let an override launch the user's installed app, or any build without
# the perf-build stamp that identifies the guarded DEBUG build.
if [[ "$app" -ef /Applications/Nook.app ]]; then
  echo "refusing to launch the installed /Applications/Nook.app" >&2
  exit 2
fi
app_real="$(cd "$app" && pwd -P)"
if [[ "$app_real" != "$repo_root"/* && "${NOOK_PERF_ALLOW_EXTERNAL_APP:-0}" != "1" ]]; then
  echo "refusing to launch an app outside $repo_root: $app_real (set NOOK_PERF_ALLOW_EXTERNAL_APP=1 to allow)" >&2
  exit 2
fi
# Perf builds are unsigned; a team signature means a distributed build.
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
if [[ -n "$team" && "$team" != "not set" ]]; then
  echo "refusing to launch an app signed by team $team: $app (perf builds are unsigned)" >&2
  exit 2
fi
# Only make perf-build stamps its DEBUG product, including incremental builds.
# Compare build identity, not mtimes or strings predating the Keychain guards.
sha="$("$repo_root/tools/perf/build-id.sh")"
binary_sha="$(/usr/libexec/PlistBuddy -c 'Print :NookBuildSHA' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$binary_sha" != "$sha" ]]; then
  echo "refusing unstamped or stale perf build: binarySha=${binary_sha:-missing} checkout=$sha (run make perf-build)" >&2
  exit 2
fi

lib_name="$(basename "$golden")"
script_name="$(basename "$script_arg")"
script_name="${script_name%.*}"
# The log name keeps the step, so per-step launches stay apart in perf-runs/.
[[ -z "$only" ]] || script_name="$script_name-${only//,/+}"
data_root="$(cd "$golden/../.." && pwd -P)"
# Feed XML is generated per library, so lib-10k never serves lib-20k's items.
feed_root="$data_root/feeds/$lib_name/$variant"
[[ -d "$feed_root" ]] || { echo "feed variant not found: $feed_root (regenerate $lib_name)" >&2; exit 1; }

port_open() {
  python3 -c 'import socket, sys; s=socket.socket(); s.settimeout(.1); ok=s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0; s.close(); raise SystemExit(0 if ok else 1)' "$port" 2>/dev/null
}
# A leftover server on the port would answer the readiness probe with the wrong variant.
if port_open; then
  echo "port $port is already in use; stop the stale feed server first (lsof -nP -iTCP:$port)" >&2
  exit 1
fi

run_dir="$repo_root/perf-runs/$label"
# The working copy keeps the library's own name so run.begin logs lib=<lib_name>.
# No excludes: --delete also resets the perf replica (<dir>/.nook-perf-replica).
working="$repo_root/perf-runs/.work/$label/$script_name-$variant/$lib_name"
mkdir -p "$run_dir" "$working"
rsync -a --delete "$golden/" "$working/"

server_log="$run_dir/feedserver-$lib_name-$script_name-$variant.log"
python3 "$repo_root/tools/perf/feedserver.py" --root "$feed_root" --port "$port" --latency-seed 7 >"$server_log" 2>&1 &
server_pid=$!
child_pid=""
watchdog_pid=""
trace_pid=""
stop_child() {
  [[ -n "$child_pid" ]] || return 0
  kill "$child_pid" 2>/dev/null || true
  # A stuck app may ignore SIGTERM. Target only the child we launched.
  sleep 1
  if kill -0 "$child_pid" 2>/dev/null; then kill -KILL "$child_pid" 2>/dev/null || true; fi
}
# Waits up to $2 seconds for PID $1 to exit.
wait_exit() {
  local _
  for _ in $(seq "$(($2 * 10))"); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  ! kill -0 "$1" 2>/dev/null
}
# Lets xctrace finish writing the .trace. A background job may inherit SIGINT
# as ignored, so escalate to TERM, then KILL, instead of waiting out
# --time-limit. Returns xctrace's status.
stop_trace() {
  [[ -n "$trace_pid" ]] || return 0
  kill -INT "$trace_pid" 2>/dev/null || true
  wait_exit "$trace_pid" 60 || { kill -TERM "$trace_pid" 2>/dev/null || true; wait_exit "$trace_pid" 10; } || kill -KILL "$trace_pid" 2>/dev/null || true
  local trace_status=0
  wait "$trace_pid" 2>/dev/null || trace_status=$?
  trace_pid=""
  return "$trace_status"
}
cleanup() {
  stop_trace || true
  [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null || true
  if [[ -n "$child_pid" ]]; then
    stop_child
    wait "$child_pid" 2>/dev/null || true
  fi
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
interrupted=0
trap 'interrupted=130; exit "$interrupted"' INT
trap 'interrupted=143; exit "$interrupted"' TERM

server_ready=0
for _ in {1..50}; do
  if kill -0 "$server_pid" 2>/dev/null; then
    if port_open; then
      server_ready=1
      break
    fi
  else
    echo "feed server exited early; see $server_log" >&2
    exit 1
  fi
  sleep 0.1
done
[[ "$server_ready" -eq 1 ]] || { echo "feed server did not become ready; see $server_log" >&2; exit 1; }

launch_args=(
  -ApplePersistenceIgnoreState YES
  -NSQuitAlwaysKeepsWindows NO
  -SUEnableAutomaticChecks NO
  -NookPerfLibrary "$working"
  -NookPerfScript "$(cd "$(dirname "$script_arg")" && pwd -P)/$(basename "$script_arg")"
  -NookPerfLabel "$label"
  -NookPerfSHA "$sha"
  -NookStallMs 50
  -autoRefreshEnabled NO
  -NookFaviconFetch NO
  -NookAICategorize NO
  -NookFreezeRelativeTime
  # Argument domain only, never persisted: no Plus session or Gemini key.
  -nookPlusSessionConfigured NO
  -geminiKeyConfigured NO
)
[[ -z "$only" ]] || launch_args+=(-NookPerfOnly "$only")
# A script may name extra argument-domain defaults (e.g. title translation on),
# so the scenario carries its own launch state.
while IFS= read -r -d '' extra; do launch_args+=("$extra"); done < <(
  python3 -c 'import json, sys; sys.stdout.write("".join(a + "\0" for a in json.load(open(sys.argv[1])).get("launchArgs", [])))' "$script_arg"
)

# Give this child an explicit log path: macOS Foundation can ignore TMPDIR.
# Never inspect or move the real app's container log.
launch_tmp="$(mktemp -d "$working/../launch.XXXXXX")"
source_log="$launch_tmp/ui-forensics.log"
n=1
while [[ -e "$run_dir/$lib_name-$script_name-$variant-$n.log" ]]; do n=$((n + 1)); done
destination="$run_dir/$lib_name-$script_name-$variant-$n.log"
timeout_marker="$launch_tmp/timeout"
launch_args+=(-NookPerfLog "$source_log")

TMPDIR="$launch_tmp/" "$executable" "${launch_args[@]}" >"$launch_tmp/stdout.log" 2>"$launch_tmp/stderr.log" &
child_pid=$!
if [[ -n "$xctrace_template" ]]; then
  # Attach by PID so the watchdog always owns the actual app child.
  trace="$run_dir/$lib_name-$script_name-$variant-$(date +%Y%m%d-%H%M%S).trace"
  xcrun xctrace record --template "$xctrace_template" --output "$trace" --time-limit "${run_timeout}s" --attach "$child_pid" &
  trace_pid=$!
fi
(
  started=$SECONDS
  while kill -0 "$child_pid" 2>/dev/null; do
    elapsed=$((SECONDS - started))
    if (( elapsed >= run_timeout )); then
      echo "total" >"$timeout_marker"
      break
    fi
    if (( elapsed >= library_timeout )) && ! grep -q 'perf\.library' "$source_log" 2>/dev/null; then
      echo "library" >"$timeout_marker"
      break
    fi
    sleep 1
  done
  if [[ -f "$timeout_marker" ]]; then stop_child; fi
) &
watchdog_pid=$!
status=0
wait "$child_pid" || status=$?
# Wait for a timeout's TERM/KILL sequence before dropping the child handle.
if [[ -f "$timeout_marker" ]]; then
  wait "$watchdog_pid" || true
else
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
fi
watchdog_pid=""
child_pid=""
trace_status=0
if [[ -n "$trace_pid" ]]; then
  stop_trace || trace_status=$?
fi

if [[ -f "$source_log" ]]; then mv "$source_log" "$destination"; else touch "$destination"; fi
if [[ -f "$timeout_marker" ]]; then
  echo "perf.driver.error reason=launch-timeout phase=$(cat "$timeout_marker") libraryLimit=$library_timeout totalLimit=$run_timeout" >>"$destination"
  echo "launch timed out; see $destination and $launch_tmp/stderr.log" >&2
  status=124
elif (( status > 128 || trace_status > 128 )); then
  echo "perf.driver.error reason=signal status=$status traceStatus=$trace_status" >>"$destination"
  echo "child or trace was killed by a signal; see $destination" >&2
  status=1
elif [[ "$status" -ne 0 ]]; then
  echo "perf.driver.error reason=child-exit status=$status traceStatus=$trace_status" >>"$destination"
  echo "child exited with status $status; see $launch_tmp/stderr.log" >&2
elif [[ "$trace_status" -ne 0 ]]; then
  echo "perf.driver.error reason=trace-exit traceStatus=$trace_status" >>"$destination"
  echo "xctrace exited with status $trace_status (the app exited 0); see $destination" >&2
  status=$trace_status
elif ! grep -q 'perf\.library' "$destination"; then
  echo "perf.driver.error reason=missing-library" >>"$destination"
  echo "no perf.library in the log; see $launch_tmp/stderr.log" >&2
  status=1
fi
echo "$destination"
[[ "$status" -eq 0 ]] || exit "$status"
if grep -q 'perf\.driver\.error' "$destination"; then exit 1; fi

# -Onone inflates app-code cost several times; keep it out of -O results.
opt="$(sed -n 's/.*run\.begin.* opt=\([^ ]*\).*/\1/p' "$destination" | tail -1)"
if [[ "$opt" != "-O" ]]; then
  echo "error: this run was built with opt=${opt:-unknown}, not -O; measure with make perf-build" >&2
  exit 1
fi
