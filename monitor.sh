#!/usr/bin/env bash
# 실행: bash /home/agent-admin/agent-app/bin/monitor.sh
# Ubuntu/Linux, Bash. Cron runs this script once per minute as agent-admin.
# Only UFW status is queried with sudo; the rest runs as the caller.

# ============================================================
# 1. 변수 선언 / configuration
# ============================================================
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 007
set -u
set -o pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
APP_NAME="agent-app-linux-x86"   # Change to agent-app-linux-arm64 or agent_app.py if needed.
APP_USER="agent-admin"
PORT="${AGENT_PORT:-15034}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$LOG_DIR/monitor.log"
LOCK_FILE="$LOG_DIR/.monitor.lock"
UFW_BIN="/usr/sbin/ufw"

CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80
CPU_SAMPLE_SECONDS=1
MAX_LOG_BYTES=$((10 * 1024 * 1024))  # 10 MiB per log file.
MAX_LOG_FILES=10                    # Current log + 9 numbered backups.
MAX_BACKUPS=$((MAX_LOG_FILES - 1))

PIDS=""
PID_TEXT=""
CPU="N/A"
MEM="N/A"
DISK_USED="N/A"
NOW=""
LOG_LINE=""
LOG_SAVED=0
HEALTH_MESSAGES=()
WARNINGS=()
ERROR_MESSAGE=""

# ============================================================
# 2. 함수 정의
# ============================================================
print_result() {
    printf '\n====== SYSTEM MONITOR RESULT ======\n\n[HEALTH CHECK]\n'
    if ((${#HEALTH_MESSAGES[@]})); then
        printf '%s\n' "${HEALTH_MESSAGES[@]}"
    fi
    if [[ -n "$ERROR_MESSAGE" ]]; then
        printf '[FAIL] %s\n' "$ERROR_MESSAGE" >&2
    fi
    printf '\n[RESOURCE MONITORING]\n'
    printf 'CPU Usage : %s%%\nMEM Usage : %s%%\nDISK Used : %s%%\n' \
        "$CPU" "$MEM" "$DISK_USED"
    if ((${#WARNINGS[@]})); then
        printf '\n'
        printf '[WARNING] %s\n' "${WARNINGS[@]}"
    fi
    if ((LOG_SAVED)); then
        printf '\n[INFO] Log appended: %s\n%s\n' "$LOG_FILE" "$LOG_LINE"
    fi
}

# Successful samples and failures share monitor.log and one rotation policy.
fail() {
    ERROR_MESSAGE="$1"
    ERROR_MESSAGE="${ERROR_MESSAGE//$'\n'/ }"
    ERROR_MESSAGE="${ERROR_MESSAGE//$'\r'/ }"
    NOW=$(date '+%Y-%m-%d %H:%M:%S') || NOW='timestamp-unavailable'
    printf -v LOG_LINE '[%s] [ERROR] %s' "$NOW" "$ERROR_MESSAGE"
    if append_log_record "$LOG_LINE"; then
        LOG_SAVED=1
    else
        printf '[WARNING] Cannot save failure to %s; error follows on stderr.\n' \
            "$LOG_FILE" >&2
    fi
    print_result
    exit 1
}
check_dependencies() {
    local command_name
    for command_name in id pgrep ps ss awk grep date df stat flock \
                        sleep sed tr tail mktemp cat mv rm; do
        command -v "$command_name" >/dev/null 2>&1 || \
            fail "Required command missing: $command_name"
    done
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || fail 'Invalid TCP port.'
    ((10#$PORT >= 1 && 10#$PORT <= 65535)) || fail 'TCP port out of range.'
}

check_process() {
    local pattern pid state
    # Escape regex metacharacters in the filename. Match a complete path component.
    pattern=$(printf '%s' "$APP_NAME" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    if ! PIDS=$(pgrep -u "$APP_USER" -f "(^|[[:space:]/])${pattern}([[:space:]]|$)"); then
        fail "Process '$APP_NAME' not found for user '$APP_USER'."
    fi
    while IFS= read -r pid; do
        state=$(ps -p "$pid" -o stat=) || state=""
        state="${state//[[:space:]]/}"
        if [[ -z "$state" ]]; then
            fail "PID $pid exited during the check."
        elif [[ "$state" =~ ^[TtZX] ]]; then
            fail "PID $pid is stopped, zombie or dead (STAT=$state)."
        elif [[ "$state" == D* ]]; then
            WARNINGS+=("PID $pid is in D state; check whether the wait persists.")
        fi
        HEALTH_MESSAGES+=("[OK] Process '$APP_NAME': PID=$pid STAT=$state")
    done <<< "$PIDS"
    PID_TEXT=$(printf '%s' "$PIDS" | tr '\n' ',')
}

check_port() {
    local sockets
    sockets=$(ss -H -ltn "sport = :$PORT") || fail 'Cannot query TCP sockets.'
    [[ -n "$sockets" ]] || fail "TCP port $PORT is not LISTENING."
    HEALTH_MESSAGES+=("[OK] TCP port $PORT is LISTENING")
}

check_firewall() {
    local output state
    if [[ ! -x "$UFW_BIN" ]]; then
        WARNINGS+=('UFW is not installed at the configured path.')
        return 0
    fi
    if output=$(sudo -n "$UFW_BIN" status 2>&1); then
        state=$(printf '%s\n' "$output" | awk '/^Status:/ {print $2; exit}')
        case "$state" in
            active) HEALTH_MESSAGES+=('[OK] UFW is active') ;;
            inactive) WARNINGS+=('UFW is inactive.') ;;
            *) WARNINGS+=('Cannot interpret UFW status.') ;;
        esac
    else
        WARNINGS+=('Cannot query UFW status; verify the restricted NOPASSWD sudo rule.')
    fi
    return 0  # A firewall warning must not stop the monitor.
}

read_cpu_counters() {
    # Sum user,nice,system,idle,iowait,irq,softirq,steal.
    # guest/guest_nice are already included in user/nice, so do not add them again.
    awk '/^cpu / {total=0; for(i=2;i<=9;i++) total+=$i;
         printf "%.0f %.0f\n", total, $5+$6; exit}' /proc/stat
 }


 collect_resources() {
    local first second total1 idle1 total2 idle2 delta_total delta_idle
    first=$(read_cpu_counters) || fail 'Cannot read /proc/stat.'
    sleep "$CPU_SAMPLE_SECONDS" || fail 'CPU sampling delay failed.'
    second=$(read_cpu_counters) || fail 'Cannot read /proc/stat.'
    read -r total1 idle1 <<< "$first"
    read -r total2 idle2 <<< "$second"
    delta_total=$((total2 - total1))
    delta_idle=$((idle2 - idle1))
    ((delta_total > 0)) || fail 'No usable CPU sampling interval.'
    # Here idle includes iowait; CPU measures active processing over the sample.
    CPU=$(awk -v t="$delta_total" -v i="$delta_idle" \
        'BEGIN {v=100*(t-i)/t; if(v<0)v=0; if(v>100)v=100; printf "%.1f",v}')
    # Available memory includes reclaimable cache; avoid counting all cache as used.
    MEM=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2; found=1}
        END {if(t<=0 || !found) exit 1; printf "%.1f",100*(t-a)/t}' /proc/meminfo) || \
        fail 'Cannot collect memory usage.'
    DISK_USED=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || \
        fail 'Cannot collect root filesystem usage.'
    [[ "$DISK_USED" =~ ^[0-9]+$ ]] || fail 'Invalid disk usage value.'
}

check_thresholds() {
    if awk -v v="$CPU" -v limit="$CPU_LIMIT" 'BEGIN {exit !(v>limit)}'; then
        WARNINGS+=("CPU threshold exceeded ($CPU% > $CPU_LIMIT%)")
    fi
    if awk -v v="$MEM" -v limit="$MEM_LIMIT" 'BEGIN {exit !(v>limit)}'; then
        WARNINGS+=("MEM threshold exceeded ($MEM% > $MEM_LIMIT%)")
    fi
    if ((DISK_USED > DISK_LIMIT)); then
        WARNINGS+=("DISK threshold exceeded ($DISK_USED% > $DISK_LIMIT%)")
    fi
}

trim_oversized_log() {
    local file="$1" size temporary
    [[ ! -L "$file" && -f "$file" ]] || return 1
    size=$(stat -c %s -- "$file") || return 1
    if ((size > MAX_LOG_BYTES)); then
        # For pre-existing oversized logs, keep the newest full lines within the cap.
        # The first tail fragment is discarded to avoid storing a partial record.
        temporary=$(mktemp "$LOG_DIR/.monitor-trim.XXXXXX") || return 1
        if tail -c "$MAX_LOG_BYTES" -- "$file" | sed '1d' > "$temporary" &&
           cat "$temporary" > "$file"; then
            rm -f -- "$temporary" || return 1
            WARNINGS+=("Oversized existing log trimmed to newest complete lines: $file")
        else
            rm -f -- "$temporary"
            return 1
        fi
    fi
}

# A subshell releases the file lock on every success/failure path.
# Return failure instead of calling fail(): avoid recursive logging errors.
append_log_record() (
    local record="$1" file suffix size line_bytes index
    [[ -d "$LOG_DIR" && -w "$LOG_DIR" && -x "$LOG_DIR" ]] || return 1
    [[ ! -L "$LOCK_FILE" ]] || return 1
    exec 9>> "$LOCK_FILE" || return 1
    flock -w 5 9 || return 1

    # Manage only monitor.log and numeric backups, never other application logs.
    for file in "$LOG_FILE" "$LOG_FILE".[0-9]*; do
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ "$file" != "$LOG_FILE" ]]; then
            suffix="${file##*.}"
            [[ "$suffix" =~ ^[1-9][0-9]*$ ]] || continue
            if ((${#suffix} > 2)) || ((10#$suffix > MAX_BACKUPS)); then
                rm -f -- "$file" || return 1
                continue
            fi
        fi
        trim_oversized_log "$file" || return 1
    done

    # LC_ALL=C means string length here is byte length, including UTF-8 messages.
    line_bytes=$((${#record} + 1))
    ((line_bytes <= MAX_LOG_BYTES)) || return 1
    size=0
    if [[ -e "$LOG_FILE" ]]; then
        size=$(stat -c %s -- "$LOG_FILE") || return 1
    fi
    if ((size + line_bytes > MAX_LOG_BYTES)); then
        rm -f -- "$LOG_FILE.$MAX_BACKUPS" || return 1
        for ((index=MAX_BACKUPS-1; index>=1; index--)); do
            if [[ -e "$LOG_FILE.$index" ]]; then
                mv -- "$LOG_FILE.$index" "$LOG_FILE.$((index+1))" || return 1
            fi
        done
        mv -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    printf '%s\n' "$record" >> "$LOG_FILE" || return 1
)


manage_and_write_log() {
    NOW=$(date '+%Y-%m-%d %H:%M:%S') || fail 'Cannot obtain timestamp.'
    printf -v LOG_LINE '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%' \
        "$NOW" "$PID_TEXT" "$CPU" "$MEM" "$DISK_USED"
    append_log_record "$LOG_LINE" || \
        fail "Cannot append or rotate log; check directory permissions, space and lock: $LOG_FILE"
    LOG_SAVED=1
}

# ============================================================
# 3. 실행 흐름: health failure -> exit 1, warnings -> continue
# ============================================================
check_dependencies
check_process
check_port
check_firewall
collect_resources
check_thresholds
manage_and_write_log

# ============================================================
# 4. 최종 출력 구간
# ============================================================
print_result
exit 0

