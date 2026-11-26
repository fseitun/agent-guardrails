#!/usr/bin/env bash
# Leftovers of Claude Code sessions. Process groups carry CLAUDECODE=1 in their
# environment and are judged by the session that spawned them: gone, idle or busy.
# Docker compose stacks are judged by who is connected to them. Lists by default and
# acts only on what is named.
set -uo pipefail

E2E_RE='(^|[-_])e2e([-_]|$)'  # compose projects that are throwaway test stacks
METRO_RE='(expo|react-native)[^ ]* +start|/metro/src/'
IDLE_AFTER=900                # seconds of quiet before a session with no job state counts as idle
protect_file=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/protected-stacks

usage() {
  cat <<'USAGE'
stale-procs.sh                    list stale and idle process groups, and docker stacks
stale-procs.sh --all              also show groups of busy sessions and stacks in use
stale-procs.sh --kill PID...      kill those groups (root + descendants)
stale-procs.sh --kill-all         kill every stale node/metro/playwright group nobody is connected to
stale-procs.sh --down PROJECT...  remove an e2e compose stack: containers, networks, volumes
stale-procs.sh --stop PROJECT...  stop a compose stack's containers, keeping its data
  --force                         with --kill, --down or --stop: act even when in use
USAGE
}

action=list force=0 show_all=0 rc=0
targets=()
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  --all) show_all=1 ;;
  --kill-all) action=kill-all ;;
  --kill|--down|--stop)
    action=${1#--}; shift
    for arg in "$@"; do [[ $arg == --force ]] && force=1 || targets+=("$arg"); done
    [[ ${#targets[@]} -gt 0 ]] || { echo "--$action needs at least one target" >&2; exit 2; }
    ;;
  *) usage; exit 2 ;;
esac
command -v jq >/dev/null || { echo "stale-procs.sh needs jq" >&2; exit 1; }

me=$(id -u)
clk=$(getconf CLK_TCK)
printf -v now '%(%s)T' -1
self_sid=${CLAUDE_CODE_SESSION_ID:-}

declare -A ppid_of=() children=() ticks0=() start_of=() agent=()
roots=()
for stat in /proc/[0-9]*/stat; do
  pid=${stat#/proc/}; pid=${pid%/stat}
  { IFS= read -r line < "$stat"; } 2>/dev/null || continue
  rest=${line##*") "}
  read -r -a f <<<"$rest"
  ppid_of[$pid]=${f[1]}
  children[${f[1]}]+=" $pid"
  ticks0[$pid]=$((f[11] + f[12]))
  start_of[$pid]=${f[19]}
done
t0=${EPOCHREALTIME/[.,]/}

while IFS= read -r environ; do
  pid=${environ#/proc/}; agent[${pid%/environ}]=1
done < <(grep -lzsx 'CLAUDECODE=1' /proc/[0-9]*/environ)
for pid in "${!agent[@]}"; do
  [[ -n ${ppid_of[$pid]:-} && -z ${agent[${ppid_of[$pid]}]:-} ]] && roots+=("$pid")
done
[[ ${#roots[@]} -gt 0 ]] && mapfile -t roots < <(printf '%s\n' "${roots[@]}" | sort -n)

descendants() {
  local pid=$1 kid
  for kid in ${children[$pid]:-}; do
    printf '%s ' "$kid"
    descendants "$kid"
  done
}

group_pids() { printf '%s %s' "$1" "$(descendants "$1")"; }
env_of() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -m1 "^$2=" | cut -d= -f2-; }
exe_path() { local exe; exe=$(readlink "/proc/$1/exe" 2>/dev/null); printf '%s' "${exe% (deleted)}"; }
exe_of() { local exe; exe=$(exe_path "$1"); printf '%s' "${exe##*/}"; }
cmd_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

fmt_dur() {
  local s=$1
  if ((s < 90)); then printf '%ds' "$s"
  elif ((s < 5400)); then printf '%dm' $((s / 60))
  elif ((s < 172800)); then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400)); fi
}

# --- sessions -------------------------------------------------------------------
# <config>/sessions/<pid>.json is Claude's own record of running sessions. An entry
# counts only while its pid is alive with the recorded start time.

declare -A loaded=() sess_pid=() sess_status=() sess_since=() sess_name=() sess_state=() pid_sess=() job_sess=()

load_registry() {
  local cfg=$1 file pid sid start status since job name
  [[ -n ${loaded[$cfg]:-} ]] && return
  loaded[$cfg]=1
  for file in "$cfg"/sessions/*.json; do
    [[ -f $file ]] || continue
    IFS=$'\x1f' read -r pid sid start status since job name < <(jq -r '
      [.pid, .sessionId, .procStart, .status // "", ((.statusUpdatedAt // 0) / 1000 | floor), .jobId // "", .name // ""]
      | map(tostring) | join("\u001f")' "$file" 2>/dev/null) || continue
    [[ -n $pid && -n $sid && ${start_of[$pid]:-} == "$start" ]] || continue
    sess_pid[$sid]=$pid sess_status[$sid]=$status sess_since[$sid]=$since sess_name[$sid]=$name
    pid_sess[$pid]=$sid
    [[ -n $job ]] || continue
    job_sess[$cfg/jobs/$job]=$sid
    sess_state[$sid]=$(jq -r '.state // ""' "$cfg/jobs/$job/state.json" 2>/dev/null)
  done
}

session_verdict() {
  local sid=$1
  [[ ${sess_status[$sid]} == busy ]] && { echo busy; return; }
  case ${sess_state[$sid]:-} in
    done|stopped) echo idle ;;
    "") ((now - sess_since[$sid] >= IDLE_AFTER)) && echo idle || echo busy ;;
    *) echo busy ;;
  esac
}

session_label() {
  local sid=$1 verdict
  verdict=$(session_verdict "$sid")
  [[ $verdict == idle ]] && verdict+=" $(fmt_dur $((now - sess_since[$sid])))"
  printf 'session %s "%s" %s' "${sid:0:8}" "${sess_name[$sid]}" "$verdict"
}

# A session this script cannot find in the registry may still be running: the group
# hangs off a claude process, or the claude process that spawned it is still alive.
# That process started before the group, so its pid cannot have been recycled.
alive_unregistered() {
  local root=$1 sid=$2 spawner=$3
  [[ $(exe_of "${ppid_of[$root]}") == claude ]] && return 0
  [[ -n $spawner && -n ${start_of[$spawner]:-} && $(exe_of "$spawner") == claude ]] &&
    ((start_of[$spawner] < start_of[$root])) && return 0
  [[ -n $sid ]] && pgrep -u "$me" -x claude -a | grep -qE -- "--(session-id|resume) $sid"
}

declare -A v_verdict=() v_label=() v_owner=()

classify() {
  local root=$1 sid cfg owner claude_pid
  [[ -n ${v_verdict[$root]:-} ]] && return
  sid=$(env_of "$root" CLAUDE_CODE_SESSION_ID)
  cfg=$(env_of "$root" CLAUDE_CONFIG_DIR); cfg=${cfg:-$HOME/.claude}
  claude_pid=$(env_of "$root" CLAUDE_PID)
  load_registry "$cfg"
  owner=${pid_sess[${ppid_of[$root]}]:-}
  [[ -z $owner && -n $sid && -n ${sess_pid[$sid]:-} ]] && owner=$sid
  [[ -z $owner && -n $claude_pid ]] && owner=${pid_sess[$claude_pid]:-}
  v_owner[$root]=${owner:-$sid}
  if [[ -n $owner ]]; then
    v_verdict[$root]=$(session_verdict "$owner")
    v_label[$root]=$(session_label "$owner")
  elif alive_unregistered "$root" "$sid" "$claude_pid"; then
    v_verdict[$root]=busy
    v_label[$root]="session ${sid:0:8} (running, not in the session registry)"
  else
    v_verdict[$root]=stale
    v_label[$root]="session ${sid:0:8} (gone)"
  fi
}

# --- sockets --------------------------------------------------------------------

declare -A ports_of=() est_pid=() est_comm=()
est_local=() est_peer=() est_owner=()

unmap() { local addr=$1; [[ $addr == \[::ffff:* ]] && { addr=${addr#\[::ffff:}; addr=${addr/\]/}; }; printf '%s' "$addr"; }

while read -r state _ _ laddr peer proc; do
  case $state in
    LISTEN)
      while [[ $proc =~ pid=([0-9]+) ]]; do
        ports_of[${BASH_REMATCH[1]}]+=" ${laddr##*:}"
        proc=${proc#*pid="${BASH_REMATCH[1]}"}
      done ;;
    ESTAB)
      [[ $laddr == \[::ffff:* ]] && laddr=$(unmap "$laddr")
      [[ $peer == \[::ffff:* ]] && peer=$(unmap "$peer")
      owner=""
      if [[ $proc =~ \(\"([^\"]*)\",pid=([0-9]+) ]]; then
        owner=${BASH_REMATCH[2]}
        est_pid[$laddr]=$owner est_comm[$laddr]=${BASH_REMATCH[1]}
      fi
      est_local+=("$laddr") est_peer+=("$peer") est_owner+=("$owner") ;;
  esac
done < <(ss -Htnpa 2>/dev/null)

add_client() {
  local who=$1
  g_clients=$((g_clients + 1))
  [[ " $g_who " == *" $who "* || $(wc -w <<<"$g_who") -ge 3 ]] || g_who+="${g_who:+ }$who"
}

clients_text() {
  ((g_clients == 0)) && { printf 'no clients'; return; }
  printf '%d client%s: %s' "$g_clients" "$( ((g_clients > 1)) && echo s)" "$g_who"
}

# Ports a group listens on, and connections into them from outside the group.
net_of() {
  local pids=" $1 " pid port i peer
  local -A mine=()
  g_ports="" g_clients=0 g_who=""
  for pid in $1; do
    for port in ${ports_of[$pid]:-}; do
      [[ -n ${mine[$port]:-} ]] || { mine[$port]=1; g_ports+=" $port"; }
    done
  done
  [[ -n $g_ports ]] || return 0
  for i in "${!est_local[@]}"; do
    [[ -n ${est_owner[$i]} && $pids == *" ${est_owner[$i]} "* ]] || continue
    [[ -n ${mine[${est_local[$i]##*:}]:-} ]] || continue
    peer=${est_peer[$i]}
    [[ -n ${est_pid[$peer]:-} && $pids == *" ${est_pid[$peer]} "* ]] && continue
    if [[ -n ${est_pid[$peer]:-} ]]; then add_client "${est_comm[$peer]}(${est_pid[$peer]})"
    else add_client "${peer%:*}"; fi
  done
}

# Connections from this machine's own processes into published host ports. The
# docker side of those sockets belongs to root and is not visible.
port_clients() {
  local port i peer host
  local -A want=()
  g_clients=0 g_who=""
  for port in $1; do want[$port]=1; done
  for i in "${!est_local[@]}"; do
    [[ -n ${est_owner[$i]} ]] || continue
    peer=${est_peer[$i]}; host=${peer%:*}
    [[ -n ${want[${peer##*:}]:-} ]] || continue
    [[ $host == 127.* || $host == "[::1]" || $host == "${est_local[$i]%:*}" ]] || continue
    add_client "${est_comm[${est_local[$i]}]}(${est_owner[$i]})"
  done
}

# --- process groups -------------------------------------------------------------

declare -A RANK=([other]=0 [node]=1 [playwright]=2 [metro]=3 [adb]=4 [kotlin]=5 [gradle]=6 [claude]=7)

# Most specific kind in the group. gradle, kotlin and adb are daemons that other
# sessions pick up and reuse; claude is a nested session.
kind_of() {
  local pid path cmd kind best=other
  for pid in $1; do
    path=$(exe_path "$pid"); cmd=$(cmd_of "$pid"); kind=other
    case ${path##*/} in
      claude) kind=claude ;;
      adb) kind=adb ;;
      java) case $cmd in *GradleDaemon*) kind=gradle ;; *KotlinCompileDaemon*) kind=kotlin ;; esac ;;
      node|bun|deno|esbuild) [[ $cmd =~ $METRO_RE ]] && kind=metro || kind=node ;;
      chrome-headless-shell) kind=playwright ;;
    esac
    [[ $path == */ms-playwright/* || $path == */puppeteer/* ]] && kind=playwright
    ((RANK[$kind] > RANK[$best])) && best=$kind
  done
  printf '%s' "$best"
}

is_private() { case $1 in node|metro|playwright) return 0 ;; *) return 1 ;; esac; }

# The process worth showing: the first one that is not a wrapper shell.
lead_of() {
  local pid
  for pid in $1; do
    case $(exe_of "$pid") in bash|sh|dash|zsh|fish|"") ;; *) printf '%s' "$pid"; return ;; esac
  done
  printf '%s' "${1%% *}"
}

rss_of() { ps -o rss= -p "$(xargs <<<"$1" | tr ' ' ',')" 2>/dev/null | awk '{s+=$1} END {printf "%dM", s/1024}'; }

# Percent of one core the group has used since the scan.
cpu_of() {
  local pid line rest ticks=0 f
  for pid in $1; do
    { IFS= read -r line < "/proc/$pid/stat"; } 2>/dev/null || continue
    rest=${line##*") "}
    read -r -a f <<<"$rest"
    ticks=$((ticks + f[11] + f[12] - ${ticks0[$pid]:-$((f[11] + f[12]))}))
  done
  printf '%d%%' $((ticks * 100000000 / clk / (${EPOCHREALTIME/[.,]/} - t0)))
}

holds_session() {
  local pid
  for pid in $1; do [[ -n ${pid_sess[$pid]:-} ]] && return 0; done
  return 1
}

is_self() { [[ -n $self_sid && ( ${v_owner[$1]} == "$self_sid" || $(env_of "$1" CLAUDE_CODE_SESSION_ID) == "$self_sid" ) ]]; }

report() {
  local root=$1 pids lead count
  pids=$(group_pids "$root"); lead=$(lead_of "$pids"); count=$(wc -w <<<"$pids")
  net_of "$pids"
  printf '%-12s %-8s age %-11s rss %-6s cpu %-5s %s\n' "[$(kind_of "$pids")]" "$root" \
    "$(ps -o etime= -p "$root" 2>/dev/null | tr -d ' ')" "$(rss_of "$pids")" "$(cpu_of "$pids")" "${v_label[$root]}"
  printf '        cwd %s\n' "$(readlink "/proc/$lead/cwd" 2>/dev/null)"
  printf '        cmd %s\n' "$(cmd_of "$lead" | cut -c1-140)"
  [[ -n $g_ports ]] && printf '        ports%s, %s\n' "$g_ports" "$(clients_text)"
  ((count > 1)) && printf '        tree %s%s\n' "$(cut -d' ' -f1-12 <<<"$pids")" "$( ((count > 12)) && echo " ... ($count processes)")"
  return 0
}

kill_group() {
  local root=$1 pids pid alive=() tries
  pids=$(group_pids "$root")
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null; done
  for tries in {1..15}; do
    alive=()
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    [[ ${#alive[@]} -eq 0 ]] && break
    sleep 0.2
  done
  if [[ ${#alive[@]} -gt 0 ]]; then
    for pid in "${alive[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    echo "killed $root (SIGKILL for ${alive[*]})"
  else
    echo "killed $root"
  fi
}

refuse() { echo "refused $1: $2" >&2; rc=1; }

kill_named() {
  local root=$1 pids
  [[ $root =~ ^[0-9]+$ ]] || { refuse "$root" "not a pid"; return; }
  [[ -d /proc/$root ]] || { echo "pid $root is already gone"; return; }
  [[ " ${roots[*]} " == *" $root "* ]] || { refuse "$root" "not the root of an agent-spawned group; pick a pid from the listing"; return; }
  classify "$root"; pids=$(group_pids "$root")
  is_self "$root" && { refuse "$root" "it belongs to the session running this script"; return; }
  holds_session "$pids" && { refuse "$root" "it contains a running Claude session"; return; }
  if ((!force)); then
    [[ ${v_verdict[$root]} == busy ]] && { refuse "$root" "${v_label[$root]}; --force to kill anyway"; return; }
    net_of "$pids"
    ((g_clients > 0)) && { refuse "$root" "$(clients_text); --force to kill anyway"; return; }
  fi
  kill_group "$root"
}

# --- docker ---------------------------------------------------------------------

declare -A st_total=() st_running=() st_ports=() st_dir=() st_status=() st_nets=() st_vols=()
docker_ok=0

scan_docker() {
  local rows project state dir status ports first last port
  command -v docker >/dev/null || return 0
  rows=$(timeout 10 docker ps -a --format $'{{.Label "com.docker.compose.project"}}\x1f{{.State}}\x1f{{.Label "com.docker.compose.project.working_dir"}}\x1f{{.Status}}\x1f{{.Ports}}' 2>/dev/null) || return 0
  docker_ok=1
  while IFS=$'\x1f' read -r project state dir status ports; do
    [[ -n $project ]] || continue
    st_total[$project]=$((${st_total[$project]:-0} + 1))
    [[ -n ${st_dir[$project]:-} ]] || st_dir[$project]=$dir
    case $state in running|restarting|paused) ;; *) continue ;; esac
    st_running[$project]=$((${st_running[$project]:-0} + 1))
    st_status[$project]=${status%% (*}
    while [[ $ports =~ :([0-9]+)(-([0-9]+))?-\> ]]; do
      first=${BASH_REMATCH[1]} last=${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}
      ports=${ports#*"${BASH_REMATCH[0]}"}
      for ((port = first; port <= last; port++)); do
        [[ " ${st_ports[$project]:-} " == *" $port "* ]] || st_ports[$project]+=" $port"
      done
    done
  done <<<"$rows"
  while IFS= read -r project; do
    [[ -n $project ]] && st_nets[$project]=$((${st_nets[$project]:-0} + 1))
  done < <(docker network ls --format '{{.Label "com.docker.compose.project"}}')
  while IFS= read -r project; do
    [[ -n $project ]] && st_vols[$project]=$((${st_vols[$project]:-0} + 1))
  done < <(docker volume ls --format '{{.Label "com.docker.compose.project"}}')
}

is_protected() {
  local pattern
  [[ -f $protect_file ]] || return 1
  while IFS= read -r pattern; do
    pattern=${pattern%%#*}; pattern=${pattern//[[:space:]]/}
    # shellcheck disable=SC2053
    [[ -n $pattern && $1 == $pattern ]] && return 0
  done < "$protect_file"
  return 1
}

# Sets s_kind, s_owner, s_busy and the client counters for a compose project. A stack
# started from a job's directory belongs to that job's session.
stack_info() {
  local project=$1 dir rest cfg="" job="" sid
  [[ $project =~ $E2E_RE ]] && s_kind=e2e || s_kind=dev
  s_owner="" s_busy=0
  dir=${st_dir[$project]:-}; rest=$dir
  while [[ $rest == */jobs/* ]]; do
    cfg+=${rest%%/jobs/*}; rest=${rest#*/jobs/}
    [[ -d $cfg/sessions ]] && { job=${rest%%/*}; break; }
    cfg+=/jobs
  done
  if [[ -n $job ]]; then
    s_owner="job $job gone"
    load_registry "$cfg"
    sid=${job_sess[$cfg/jobs/$job]:-}
    if [[ -n $sid ]]; then
      s_owner=$(session_label "$sid")
      [[ $(session_verdict "$sid") == busy ]] && s_busy=1
    fi
  elif [[ -n $dir && ! -d $dir ]]; then
    s_owner="directory gone"
  fi
  port_clients "${st_ports[$project]:-}"
}

stack_use() {
  local use=""
  ((s_busy)) && use="owner session busy"
  ((g_clients > 0)) && use+="${use:+, }$(clients_text)"
  printf '%s' "$use"
}

report_stack() {
  local project=$1 running total use what
  running=${st_running[$project]:-0}; total=${st_total[$project]:-0}
  stack_info "$project"; use=$(stack_use)
  if ((!show_all)); then
    if [[ $s_kind == e2e ]]; then ((s_busy)) && return 1
    else ((running > 0)) && [[ -z $use ]] || return 1; fi
  fi
  [[ $s_kind == dev && $total -eq 0 ]] && return 1
  if ((total == 0)); then what="no containers left, ${st_nets[$project]:-0} network(s), ${st_vols[$project]:-0} volume(s)"
  elif ((running == 0)); then what="0/$total running"
  else what="$running/$total ${st_status[$project],,}"; fi
  printf '%-12s %-30s %s\n' "[$s_kind]" "$project" "$what"
  ((running > 0)) && printf '        ports%s, %s\n' "${st_ports[$project]:- none}" "${use:-no clients}"
  [[ $s_kind == e2e && -n ${st_dir[$project]:-} ]] && printf '        dir %s%s\n' "${st_dir[$project]}" "${s_owner:+  ($s_owner)}"
  return 0
}

stack_ids() { docker "$1" ls -q --filter "label=com.docker.compose.project=$2"; }

# Shared checks for --down and --stop; leaves stack_info's results set.
stack_target() {
  local project=$1
  ((docker_ok)) || { refuse "$project" "docker is not available"; return 1; }
  is_protected "$project" && { refuse "$project" "listed in $protect_file"; return 1; }
  [[ -n ${st_total[$project]:-}${st_nets[$project]:-}${st_vols[$project]:-} ]] || { refuse "$project" "no compose project by that name"; return 1; }
  stack_info "$project"
  ((force)) || [[ -z $(stack_use) ]] || { refuse "$project" "$(stack_use); --force to act anyway"; return 1; }
}

stack_down() {
  local project=$1 containers networks volumes
  [[ $project =~ $E2E_RE ]] || { refuse "$project" "not an e2e stack, so its data is not disposable; use --stop"; return; }
  stack_target "$project" || return
  mapfile -t containers < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
  mapfile -t networks < <(stack_ids network "$project")
  mapfile -t volumes < <(stack_ids volume "$project")
  [[ ${#containers[@]} -eq 0 ]] || docker rm -f -v "${containers[@]}" >/dev/null || rc=1
  [[ ${#networks[@]} -eq 0 ]] || docker network rm "${networks[@]}" >/dev/null || rc=1
  [[ ${#volumes[@]} -eq 0 ]] || docker volume rm "${volumes[@]}" >/dev/null || rc=1
  echo "removed $project: ${#containers[@]} container(s), ${#networks[@]} network(s), ${#volumes[@]} volume(s)"
}

stack_stop() {
  local project=$1 containers
  stack_target "$project" || return
  mapfile -t containers < <(docker ps -q --filter "label=com.docker.compose.project=$project")
  [[ ${#containers[@]} -gt 0 ]] || { echo "$project has no running containers"; return; }
  docker stop "${containers[@]}" >/dev/null || { rc=1; return; }
  echo "stopped $project: ${#containers[@]} container(s), data kept. Restart: docker compose -p $project start"
}

# --- main -----------------------------------------------------------------------

# If the session running this script is missing from the registry, the registry
# cannot be trusted to tell live sessions from dead ones.
registry_ok=1
if [[ -n $self_sid ]]; then
  load_registry "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [[ -n ${sess_pid[$self_sid]:-} ]] || registry_ok=0
fi

section() {
  local title=$1 verdict=$2 root shown=0
  for root in "${roots[@]}"; do
    [[ ${v_verdict[$root]} == "$verdict" ]] || continue
    is_self "$root" && continue
    holds_session "$(group_pids "$root")" && continue
    ((shown++)) || printf '%s\n' "$title"
    report "$root"
  done
  ((shown)) && echo
  return 0
}

case $action in
  kill)
    for target in "${targets[@]}"; do kill_named "$target"; done
    ;;
  kill-all)
    ((registry_ok)) || { echo "refused: this session is not in the session registry, so live sessions cannot be told from dead ones" >&2; exit 1; }
    for root in "${roots[@]}"; do
      classify "$root"; pids=$(group_pids "$root")
      [[ ${v_verdict[$root]} == stale ]] && is_private "$(kind_of "$pids")" || continue
      net_of "$pids"
      ((g_clients > 0)) && { echo "skipped $root: $(clients_text)"; continue; }
      kill_group "$root"
    done
    ;;
  down|stop)
    scan_docker
    for target in "${targets[@]}"; do "stack_$action" "$target"; done
    ;;
  list)
    for root in "${roots[@]}"; do classify "$root"; done
    scan_docker
    elapsed=$((${EPOCHREALTIME/[.,]/} - t0))
    ((elapsed < 500000)) && sleep "0.$(printf '%06d' $((500000 - elapsed)))"
    ((registry_ok)) || printf 'WARNING: this session is not in the session registry. Groups marked gone may belong to live sessions; --kill-all is disabled.\n\n'
    out=$(
      section "Stale: the session that started these is gone" stale
      section "Idle: the session is still open but finished or waiting" idle
      ((show_all)) && section "Busy: the session is working (not stale)" busy
      if ((docker_ok)); then
        stacks=$(printf '%s\n' "${!st_total[@]}" "${!st_nets[@]}" "${!st_vols[@]}" | sort -u)
        shown=0 protected=""
        for project in $stacks; do
          is_protected "$project" && { protected+=" $project"; continue; }
          lines=$(report_stack "$project") || continue
          ((shown++)) || echo "Docker compose stacks"
          printf '%s\n' "$lines"
        done
        [[ -n $protected ]] && printf 'protected, not shown:%s\n' "$protected"
        ((shown)) || [[ -n $protected ]] && echo
      fi
    )
    if [[ -z $out ]]; then
      echo "Nothing stale: no leftover agent-spawned processes$( ((docker_ok)) && echo " or docker stacks")."
    else
      printf '%s\n\n' "$out"
      echo "processes: $0 --kill <pid>   |   every stale node/metro/playwright group: --kill-all"
      ((docker_ok)) && echo "docker:    $0 --down <e2e project> (deletes its data)   |   --stop <project> (keeps data)"
    fi
    ;;
esac
exit "$rc"
