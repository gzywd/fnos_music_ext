#!/bin/bash
# ==============================================================================
# fnmusic-ext fpk 共享函数库
#
# 设计要点：
#   1. 生命周期脚本（cmd/*）以 root 运行，因为「接管 /var/run/trim_music.socket」
#      必须在 /var/run 下重命名与新建 socket 文件，包用户没有该目录写权限。
#   2. 网易云音源服务（musicbox）不对外暴露接管能力，按官方要求降权到
#      $TRIM_USERNAME（专用包用户）运行。
#   3. 代理进程无法降权：uvicorn 需要在 /var/run 下创建 bind socket，非 root
#      缺少目录写权限。这是 socket 接管架构的固有代价，已在 README / fpk
#      文档中明示。
#   4. 全部运行时代码 stage 到 $RUN_DIR（= $TRIM_PKGVAR/app），使其目录布局
#      与仓库根完全一致，从而**原样复用** proxy/run_proxy.sh 与 restore.sh 中
#      已经过生产验证的 socket 接管 / 复位逻辑，不在 fpk 里另写一份。
#
# 依赖：仅 bash / coreutils / curl / jq（jq 缺失时扫码登录脚本会自行降级）
# ==============================================================================

APP_NAME="fnmusicext"
PYTHON_APP="python312"
PYTHON_BIN="/var/apps/${PYTHON_APP}/target/bin"

APPDEST="${TRIM_APPDEST:-/var/apps/${APP_NAME}/target}"
# 官方框架：var -> /vol{n}/@appdata/{appname}，对应 TRIM_PKGVAR
# （仅在环境变量缺失时兜底；正常由飞牛注入，不要依赖这个默认值）
PKGVAR="${TRIM_PKGVAR:-$(ls -d /vol*/@appdata/${APP_NAME} 2>/dev/null | head -n 1)}"
PKGVAR="${PKGVAR:-/vol1/@appdata/${APP_NAME}}"
RUN_DIR="${PKGVAR}/app"
LOG_DIR="${PKGVAR}/logs"
ENV_FILE="${RUN_DIR}/.env"

# 网易云登录凭证（cookie）与 NEMbox 运行时数据的**持久目录**。
#
# 必须放在 ${PKGVAR} 下、RUN_DIR 之外：RUN_DIR(=${PKGVAR}/app) 是每次安装都会被
# stage 覆盖、并在「卸载 + 重装」流程里被整体 rm -rf 的运行目录。此前凭证放在
# ${RUN_DIR}/musicbox-data，于是手动安装新版 fpk（走卸载+安装而非升级）就会把
# cookie 一起删掉，用户每装一次就得重新扫码一次 —— 频繁扫码登录正是网易云风控
# 最敏感的行为之一。
#
# ${PKGVAR}/logs 能跨安装留存（诊断日志里能看到多次安装的历史），证明 PKGVAR 本身
# 在卸载/重装后不会被清空，因此凭证放这里可以真正跨版本持久。
MUSICBOX_DATA_DIR="${PKGVAR}/musicbox-data"
# 旧版凭证位置（迁移用）
LEGACY_MUSICBOX_DATA_DIR="${RUN_DIR}/musicbox-data"


lib_migrate_musicbox_data() {
    # 把旧位置 ${RUN_DIR}/musicbox-data 下的 cookie 等凭证迁到持久目录。
    # 幂等：新位置已有 cookie 就不动（宁可用新的登录，也不覆盖用户刚扫的码）；
    # 只在新位置缺失、旧位置存在时搬迁，且不删除旧目录（交回给 stage/卸载逻辑处理）。
    local legacy="${LEGACY_MUSICBOX_DATA_DIR}"
    [ -d "${legacy}" ] || return 0

    local legacy_cookie new_cookie
    legacy_cookie="$(find "${legacy}" -maxdepth 3 -name 'cookie.txt' -type f 2>/dev/null | head -n 1)"
    [ -n "${legacy_cookie}" ] || return 0

    new_cookie="${MUSICBOX_DATA_DIR}/netease-musicbox/cookie.txt"
    if [ -s "${new_cookie}" ]; then
        return 0
    fi

    mkdir -p "${MUSICBOX_DATA_DIR}" 2>/dev/null || return 0
    # 逐个文件复制，保留权限与时间戳；目录结构照搬
    ( cd "${legacy}" && find . -type d -print0 2>/dev/null ) |
        while IFS= read -r -d '' d; do
            mkdir -p "${MUSICBOX_DATA_DIR}/${d}" 2>/dev/null || true
        done
    ( cd "${legacy}" && find . -type f -print0 2>/dev/null ) |
        while IFS= read -r -d '' f; do
            [ -e "${MUSICBOX_DATA_DIR}/${f}" ] && continue
            cp -a "${legacy}/${f}" "${MUSICBOX_DATA_DIR}/${f}" 2>/dev/null || true
        done

    if [ -s "${new_cookie}" ]; then
        lib_log "已迁移网易云登录凭证到持久目录 ${MUSICBOX_DATA_DIR}"
        lib_chown_musicbox_data
    fi
    return 0
}


lib_chown_musicbox_data() {
    # cookie 是敏感凭证：先无条件收紧到 0600，再在能确定包用户时改属主。
    # 顺序很重要——原先 chmod 被写在 `TRIM_USERNAME 存在` 的判断之后，
    # 一旦拿不到包用户名（异常环境）敏感文件就保持 644，本机其他用户可读。
    find "${MUSICBOX_DATA_DIR}" -name 'cookie.txt' -type f -exec chmod 600 {} + 2>/dev/null || true

    # 登录凭证必须归包用户所有：降权运行的 musicbox 进程才写得出 cookie；
    # 属主错了扫码会"看起来成功但落不了盘"。
    local target="${TRIM_USERNAME:-}"
    [ -n "${target}" ] || return 0
    id "${target}" >/dev/null 2>&1 || return 0
    chown -R "${target}:${TRIM_GROUPNAME:-${target}}" "${MUSICBOX_DATA_DIR}" 2>/dev/null || true
}


lib_ensure_musicbox_data_dirs() {
    mkdir -p "${MUSICBOX_DATA_DIR}/cache/netease-musicbox" \
             "${MUSICBOX_DATA_DIR}/config/netease-musicbox" \
             "${MUSICBOX_DATA_DIR}/netease-musicbox" 2>/dev/null || true
    chmod 700 "${MUSICBOX_DATA_DIR}" 2>/dev/null || true
    lib_chown_musicbox_data
}

PROXY_PID="${PKGVAR}/proxy.pid"
MUSICBOX_PID="${PKGVAR}/musicbox.pid"
UI_PID="${PKGVAR}/ui.pid"
PROXY_LOG="${LOG_DIR}/proxy.log"
MUSICBOX_LOG="${LOG_DIR}/musicbox.log"
UI_LOG="${LOG_DIR}/ui.log"
INFO_LOG="${LOG_DIR}/info.log"

# 管理页面的 unix socket。官方要求 gatewaySocket 放在已安装应用的 target 目录下，
# 因此这里用 APPDEST 而不是 PKGVAR；网关按 ui/config 里的 gatewaySocket 文件名找它。
UI_SOCK="${APPDEST}/ui.sock"

TARGET_SOCK="/var/run/trim_music.socket"
UPSTREAM_SOCK="/var/run/trim_music_upstream.socket"
MUSICBOX_PORT="${FNMUSIC_MUSICBOX_PORT:-8770}"
MUSICBOX_URL="http://127.0.0.1:${MUSICBOX_PORT}"

lib_log() {
    mkdir -p "${LOG_DIR}" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "${INFO_LOG}" 2>/dev/null
}

# 生命周期脚本失败时，用户可见错误必须写入 TRIM_TEMP_LOGFILE（官方约定）
lib_fail() {
    local msg="$1"
    lib_log "ERROR: ${msg}"
    if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
        echo "${msg}" >> "${TRIM_TEMP_LOGFILE}" 2>/dev/null
    fi
    echo "[fnmusic-ext] ${msg}" >&2
}

lib_warn() {
    lib_log "WARN: $*"
    if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
        echo "警告: $*" >> "${TRIM_TEMP_LOGFILE}" 2>/dev/null
    fi
    echo "[fnmusic-ext] 警告: $*" >&2
}

lib_python() {
    # 官方运行时包路径优先；缺失时回落到系统 python3（便于开发机自测）
    if [ -x "${PYTHON_BIN}/python3" ]; then
        echo "${PYTHON_BIN}/python3"
    else
        command -v python3 || echo ""
    fi
}

lib_check_python() {
    local py
    py="$(lib_python)"
    if [ -z "${py}" ]; then
        lib_fail "找不到 Python 运行时。请确认已在应用中心安装依赖包 ${PYTHON_APP}，或系统存在 python3。"
        return 1
    fi
    if [ ! -x "${PYTHON_BIN}/python3" ]; then
        lib_warn "未检测到 ${PYTHON_BIN}/python3，改用系统 python3（$(py_ver "${py}")）。生产环境建议安装 ${PYTHON_APP} 依赖包。"
    fi
    echo "${py}"
    return 0
}

py_ver() {
    "$1" -c 'import sys;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || echo "unknown"
}

lib_pid_alive() {
    local file="$1"
    [ -r "${file}" ] || return 1
    local pid
    pid="$(head -n 1 "${file}" | tr -d '[:space:]')"
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

# TERM -> 等待 -> KILL 两段式停止（官方 native 案例同款模式）
lib_stop_pid() {
    local name="$1" file="$2" wait_s="${3:-15}"
    if ! lib_pid_alive "${file}"; then
        rm -f "${file}" 2>/dev/null
        lib_log "${name} 未在运行，跳过停止"
        return 0
    fi
    local pid count=0
    pid="$(head -n 1 "${file}" | tr -d '[:space:]')"
    lib_log "停止 ${name} (pid=${pid})，发送 TERM..."
    kill -TERM "${pid}" 2>/dev/null || true
    while kill -0 "${pid}" 2>/dev/null && [ "${count}" -lt "${wait_s}" ]; do
        sleep 1
        count=$((count + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        lib_log "${name} ${wait_s}s 内未退出，发送 KILL"
        kill -KILL "${pid}" 2>/dev/null || true
        sleep 1
    fi
    rm -f "${file}" 2>/dev/null
    lib_log "${name} 已停止"
    return 0
}

lib_wait_http() {
    local url="$1" tries="${2:-30}" interval="${3:-1}" i=0
    while [ "${i}" -lt "${tries}" ]; do
        if curl -s --max-time 3 -f "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep "${interval}"
        i=$((i + 1))
    done
    return 1
}

lib_read_env_value() {
    local key="$1" default="${2:-}"
    if [ -r "${ENV_FILE}" ]; then
        local v
        v="$(sed -n "s/^${key}='\{0,1\}\([^']*\)'\{0,1\}\s*$/\1/p" "${ENV_FILE}" 2>/dev/null | tail -n 1)"
        if [ -n "${v}" ]; then
            echo "${v}"
            return 0
        fi
    fi
    echo "${default}"
}

# ------------------------------------------------------------------------------
# 降级运行：把不需要 root 的进程切到专用包用户
# ------------------------------------------------------------------------------

# 探测当前是否【能够】降权到目标用户。用一条空命令试探，避免把子命令自身的
# 失败误判为"降权不可用"。结果缓存，避免每个进程都试一次。
_DROP_CAPABLE=""
lib_can_drop_to() {
    local target="$1"
    if [ -n "${_DROP_CAPABLE}" ]; then
        # 已探测过：no 表示不可降权，其余（yes / yes:su）表示可降权
        [ "${_DROP_CAPABLE}" != "no" ]
        return $?
    fi
    _DROP_CAPABLE="no"
    if [ "$(id -un)" = "root" ] && id "${target}" >/dev/null 2>&1; then
        if command -v runuser >/dev/null 2>&1 && runuser -u "${target}" -- /bin/true >/dev/null 2>&1; then
            _DROP_CAPABLE="yes"
        elif command -v su >/dev/null 2>&1 && su -s /bin/bash "${target}" -c '/bin/true' >/dev/null 2>&1; then
            _DROP_CAPABLE="yes:su"
        fi
    fi
    [ "${_DROP_CAPABLE}" != "no" ]
}

lib_as_app_user() {
    # 用法：lib_as_app_user <cmd> [args...]
    #
    # 官方要求「长期运行并对外提供访问的进程应尽可能以非 root 用户运行」，
    # 因此音源服务尽量降权。降权确实不可用时（受限容器 / 包用户未创建）
    # 如实告警后继续以当前身份运行，而不是让整个应用启动失败。
    local target="${TRIM_USERNAME:-}"
    if [ -z "${target}" ] || [ "$(id -un)" = "${target}" ]; then
        # 没有可降权的目标，或本来就是该用户 —— 无需降权
        "$@"
        return $?
    fi

    # 先调用探测（会设置全局 _DROP_CAPABLE），再读结果——
    # 不能放进 $( ) 里，子 shell 会把缓存丢掉。
    local can=1
    lib_can_drop_to "${target}" && can=0

    if [ "${can}" -eq 0 ]; then
        case "${_DROP_CAPABLE}" in
            yes)
                runuser -u "${target}" -- "$@"
                return $?
                ;;
            yes:su)
                su -s /bin/bash "${target}" -c "$(printf '%q ' "$@")"
                return $?
                ;;
        esac
    fi

    lib_warn "无法降权到用户 ${target}（受限环境或该用户不存在），改以 $(id -un) 运行：$(basename "$1")"
    "$@"
}

# ------------------------------------------------------------------------------
# 后台守护进程启动：pidfile 必须指向真身
# ------------------------------------------------------------------------------
#
# 直接把「函数调用」放到后台再取 $! 是错的：$! 拿到的是执行该函数的 bash 子壳，
# 子壳随后退出、真正的服务进程被 reparent 到 init，于是 stop 时 kill 的是一个
# 早已死亡的 PID，服务进程永久泄漏。降权场景更糟——runuser/su 是中间父进程，
# 且默认不转发信号。
#
# 解法：让子进程【自己】把 $$ 写进 pidfile，然后 exec 成目标程序。
# bash -c 里的 $$ 与 exec 后的进程 PID 相同，所以 pidfile 永远指向服务真身，
# 中间的 runuser/su 是否存活都不影响停机准确性。
lib_spawn() {
    # 用法: lib_spawn <pidfile> <logfile> [--as-root] <cmd> [args...]
    #   --as-root  显式要求以当前(root)身份运行，不降权。
    #              只用于必须在 /var/run 下创建 bind socket 的代理进程。
    local pidfile="$1" logfile="$2"
    shift 2
    local force_root=0
    if [ "${1:-}" = "--as-root" ]; then
        force_root=1
        shift
    fi
    mkdir -p "$(dirname "${logfile}")" 2>/dev/null

    local inner script
    inner="$(printf '%q ' "$@")"
    script="printf '%s' \$\$ > $(printf '%q' "${pidfile}"); exec ${inner}"

    local target="${TRIM_USERNAME:-}"
    if [ "${force_root}" -eq 0 ] && [ -n "${target}" ] && [ "$(id -un)" != "${target}" ]; then
        local can=1
        lib_can_drop_to "${target}" && can=0
        if [ "${can}" -eq 0 ] && [ "${_DROP_CAPABLE}" = "yes" ]; then
            runuser -u "${target}" -- bash -c "${script}" >> "${logfile}" 2>&1 &
            return 0
        elif [ "${can}" -eq 0 ]; then
            su -s /bin/bash "${target}" -c "$(printf '%q ' bash -c "${script}")" \
                >> "${logfile}" 2>&1 &
            return 0
        fi
        lib_warn "无法降权到 ${target}，以 $(id -un) 启动：$(basename "$1")"
    fi
    bash -c "${script}" >> "${logfile}" 2>&1 &
    return 0
}

lib_wait_pidfile() {
    # pidfile 由子进程自己写入，启动瞬间可能还没落盘，最多等 5s
    local file="$1" i=0
    while [ "${i}" -lt 50 ]; do
        if [ -s "${file}" ] && lib_pid_alive "${file}"; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    [ -s "${file}" ] && lib_pid_alive "${file}"
}

lib_kill_stale_by_sock() {
    # 兜底清理：pidfile 丢失（例如启动竞态下被误删）但进程仍在监听我们的 socket 时，
    # 按【本应用自己的 socket 绝对路径】精确匹配并终止，绝不波及任何其它 uvicorn。
    #
    # 没有这道网，一次启动竞态就会留下一个永久孤儿进程：它占着 ui.sock，
    # 下次启动又因 socket 已存在而行为诡异，用户只能重启整机。
    local sock="$1"
    [ -n "${sock}" ] || return 0
    [ -S "${sock}" ] || return 0

    local needles=("uds ${sock}" "uds=${sock}")
    local pids="" line pid args needle hit
    while IFS= read -r line; do
        pid="${line%% *}"
        args="${line#* }"
        hit=0
        for needle in "${needles[@]}"; do
            case "${args}" in *"${needle}"*) hit=1; break ;; esac
        done
        [ "${hit}" -eq 1 ] || continue
        case "${pid}" in ''|*[!0-9]*) continue ;; esac
        pids="${pids} ${pid}"
    done < <(ps -eo pid=,args= 2>/dev/null)

    pids="$(echo "${pids}" | tr -s ' ')"
    [ -n "${pids// /}" ] || return 0

    lib_log "发现绑定 ${sock} 的孤儿进程:${pids}，执行清理"
    # 先 TERM 再 KILL，并跳过自己与父进程，避免自杀
    local self=$$ parent=${PPID:-0}
    for pid in ${pids}; do
        [ "${pid}" = "${self}" ] && continue
        [ "${pid}" = "${parent}" ] && continue
        kill -TERM "${pid}" 2>/dev/null || true
    done
    sleep 2
    for pid in ${pids}; do
        [ "${pid}" = "${self}" ] && continue
        [ "${pid}" = "${parent}" ] && continue
        kill -0 "${pid}" 2>/dev/null && {
            lib_log "孤儿进程 ${pid} 未响应 TERM，发送 KILL"
            kill -KILL "${pid}" 2>/dev/null || true
        }
    done
    rm -f "${sock}" 2>/dev/null
    return 0
}

lib_rotate_logs() {
    # 日志保留策略：单文件超上限就轮转成 .1 备份，超龄文件直接删。
    # 默认 10MB / 30 天，可由 .env 的 FNMUSIC_LOG_MAX_MB / FNMUSIC_LOG_MAX_DAYS 覆盖。
    # 只在【启动前】调用（此时没有进程持有日志 fd，rename 安全）；
    # 运行期由管理页面进程用 loghouse.scan() 就地截断，避免 inode 被带走。
    local max_mb max_days keep
    max_mb="$(lib_read_env_value FNMUSIC_LOG_MAX_MB 10)"
    max_days="$(lib_read_env_value FNMUSIC_LOG_MAX_DAYS 30)"
    case "${max_mb}" in ''|*[!0-9.]*) max_mb=10 ;; esac
    case "${max_days}" in ''|*[!0-9.]*) max_days=30 ;; esac
    keep=1

    [ -d "${LOG_DIR}" ] || return 0

    local max_bytes
    max_bytes="$(awk -v m="${max_mb}" 'BEGIN{printf "%d", m*1048576}')"
    local cutoff
    cutoff="$(awk -v d="${max_days}" 'BEGIN{printf "%d", systime() - d*86400}')" 2>/dev/null || cutoff=0

    local f name size mtime freed=0 acted=0
    for f in "${LOG_DIR}"/*.log "${LOG_DIR}"/*.log.*; do
        [ -f "${f}" ] || continue
        name="$(basename "${f}")"
        size="$(stat -c %s "${f}" 2>/dev/null || echo 0)"
        mtime="$(stat -c %Y "${f}" 2>/dev/null || echo 0)"

        # 超龄：备份直接删，活跃日志清空（可能仍有进程持有 fd，不能 unlink）
        if [ "${max_days}" != "0" ] && [ "${cutoff}" -gt 0 ] && [ "${mtime}" -lt "${cutoff}" ]; then
            case "${name}" in
                *.log.[0-9]*)
                    rm -f "${f}" 2>/dev/null && { freed=$((freed + size)); acted=$((acted+1)); }
                    lib_log "清理超龄备份日志 ${name}（$((size / 1024)) KB）"
                    continue ;;
                *)
                    : > "${f}" 2>/dev/null && { freed=$((freed + size)); acted=$((acted+1)); }
                    lib_log "清空超龄日志 ${name}（$((size / 1024)) KB）"
                    continue ;;
            esac
        fi

        # 超大：活跃日志轮转成 .1（启动前无写入端持有 fd，rename 安全）
        if [ "${max_mb}" != "0" ] && [ "${size}" -gt "${max_bytes}" ]; then
            case "${name}" in
                *.log)
                    rm -f "${f}.${keep}" 2>/dev/null
                    for ((n = keep; n > 1; n--)); do
                        [ -f "${f}.$((n - 1))" ] && mv -f "${f}.$((n - 1))" "${f}.${n}" 2>/dev/null
                    done
                    mv -f "${f}" "${f}.1" 2>/dev/null || continue
                    : > "${f}" 2>/dev/null
                    chmod 644 "${f}" 2>/dev/null
                    freed=$((freed + size)); acted=$((acted + 1))
                    lib_log "轮转超大日志 ${name}（$((size / 1048576)) MB > ${max_mb} MB）"
                    ;;
                *)
                    rm -f "${f}" 2>/dev/null && { freed=$((freed + size)); acted=$((acted+1)); }
                    ;;
            esac
        fi
    done
    [ "${acted}" -gt 0 ] && lib_log "日志清理完成：${acted} 个文件，回收 $((freed / 1048576)) MB"
    return 0
}

lib_probe_proxy() {
    # 判「socket 接管是否仍由本扩展代理持有」——只认 socket 属主，不依赖外网。
    #
    # 背景（v2.9.30 修复）：旧逻辑只 curl healthz 一次、3s 超时。而 /_ext/healthz
    # 内部会连官方后端做一次网易云搜索探测（healthz_probe），外网断时官方后端
    # search 超时/5xx 会让 healthz 整体变慢，curl 3s 拿不到响应就误判「接管丢失」，
    # 看门狗于是把**健康的代理**杀掉重启（表现为「断网后反复重启/未启用」）。
    #
    # 现在改为：能拿到本扩展 healthz 响应（含 "upstream" 字段，无论 ok/fail）即视为
    # 本代理持有 socket → 健康；首次连不上时再补一次官方属主探针——只有 socket 确实
    # 被官方 trim-music 抢走（返回 INVALID TOKEN），才判定「接管丢失」需要恢复，
    # 其余情况（代理瞬时忙 / 外网慢拖慢 healthz）都不再误杀。
    local resp probe
    resp="$(curl -s --max-time 8 --unix-socket "${TARGET_SOCK}" http://localhost/_ext/healthz 2>/dev/null || true)"
    case "${resp}" in
        *'"upstream"'*) return 0 ;;
    esac
    # 追加官方属主探针，确认 socket 究竟归谁
    probe="$(curl -s --max-time 3 --unix-socket "${TARGET_SOCK}" "http://localhost/music/api/v1/search/track?keyword=probe" 2>/dev/null || true)"
    case "${probe}" in
        *'INVALID TOKEN'*|*'"code":99999'*|*'code:99999'*) return 1 ;; # 官方持有→接管丢失
        *) return 0 ;;                                                 # 仍视为本代理持有
    esac
}


# ------------------------------------------------------------------------------
# 重启标记：管理页保存配置后的「停代理 → 起代理」窗口里，应用状态会短暂变为
# 未运行。飞牛桌面据此回收应用窗口/网关路由，用户看到的就是「保存即闪退」。
# 有 fresh 标记时 status.sh 应继续报 running，窗口不再被收走。
# ------------------------------------------------------------------------------

RESTART_MARKER="${PKGVAR}/restart.inprogress"
# 标记最大有效期（秒）：restart 脚本被 kill -9 留下死标记时，最多谎报这么久
RESTART_MARKER_MAX_AGE="${FNMUSICEXT_RESTART_MARKER_MAX_AGE:-300}"

lib_restart_marker_begin() {
    mkdir -p "${PKGVAR}" 2>/dev/null || true
    printf '%s\n' "$(date +%s)" > "${RESTART_MARKER}" 2>/dev/null || true
}

lib_restart_marker_end() {
    rm -f "${RESTART_MARKER}" 2>/dev/null || true
}

lib_restart_in_progress() {
    [ -f "${RESTART_MARKER}" ] || return 1
    local mtime now age
    mtime="$(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( now - mtime ))
    [ "${age}" -ge 0 ] && [ "${age}" -le "${RESTART_MARKER_MAX_AGE}" ]
}

# ------------------------------------------------------------------------------
# 接管丢失标记（v2.9.26）
#
# `status` 的语义是「这个应用**是否处于启用状态**」，不是「这一刻 socket 有没有
# 接管成功」——飞牛按 exit 3 把应用置为「未启用」，而这个状态**不会因为我们的
# 看门狗自愈而自动翻回来**，用户必须手动再点一次「启用」。
#
# 官方 trim-music 重启会重绑 /var/run/trim_music.socket 把接管抢走，代理进程本身
# 毫发无损、看门狗几十秒内就能恢复。以前 status 见到接管丢失一律 exit 3，等于
# **一边用看门狗自愈、一边告诉系统自己没在运行**——两个机制打架，用户看到的就是
# 「明明一切正常，应用却显示未启用，还得我手动点回来」。
#
# 所以这里给「接管丢失」一个宽限窗口：窗口内仍报 running。超过宽限期还恢复不了，
# 说明看门狗确实救不回来，那时才诚实报「未运行」让人介入。
# ------------------------------------------------------------------------------

TAKEOVER_LOST_MARKER="${PKGVAR}/takeover.lost"
# 宽限时长（秒）。看门狗 30s 一轮、恢复通常 1~2 分钟内完成，给 10 分钟足够。
TAKEOVER_GRACE_S="${FNMUSICEXT_TAKEOVER_GRACE_S:-600}"

lib_takeover_lost_age() {
    mkdir -p "${PKGVAR}" 2>/dev/null || true
    if [ ! -f "${TAKEOVER_LOST_MARKER}" ]; then
        printf '%s\n' "$(date +%s)" > "${TAKEOVER_LOST_MARKER}" 2>/dev/null || true
        echo 0
        return 0
    fi
    local mtime now
    mtime="$(stat -c %Y "${TAKEOVER_LOST_MARKER}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    echo $(( now - mtime ))
}

lib_takeover_lost_clear() {
    rm -f "${TAKEOVER_LOST_MARKER}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 主动停机标志（v2.7）：stop.sh 落盘、start.sh 清除（看门狗发起的恢复除外）。
#
# 看门狗（watchdog.sh）的职责是把「死掉的代理 / 丢失的 socket 接管」自动拉起来，
# 因此它必须能区分「服务出故障了」和「用户/系统主动停机」。没有这个标志，
# 用户在应用中心点「停止」后，看门狗会在 30s 内把服务原样拉回来——
# 表现为「停不掉的应用」。标志落在 PKGVAR（跨卸载重装持久），所以
# start.sh 只在【非看门狗】调用时清除它。
# ------------------------------------------------------------------------------

STOPPED_FLAG="${PKGVAR}/stopped.flag"

lib_stopped_flag_set() {
    [ -f "${STOPPED_FLAG}" ]
}

lib_stopped_flag_mark() {
    mkdir -p "${PKGVAR}" 2>/dev/null || true
    printf '%s\n' "$(date +%s)" > "${STOPPED_FLAG}" 2>/dev/null || true
}

lib_stopped_flag_clear() {
    rm -f "${STOPPED_FLAG}" 2>/dev/null || true
}

# 看门狗 PID 与轮询间隔。间隔从 .env 读（FNMUSIC_WATCHDOG_INTERVAL_S），
# 0 或负数 = 关闭看门狗。
WATCHDOG_PID="${PKGVAR}/watchdog.pid"

lib_watchdog_interval() {
    local v
    v="$(lib_read_env_value FNMUSIC_WATCHDOG_INTERVAL_S 30)"
    case "${v}" in
        ''|*[!0-9]*) echo 30 ;;
        *) echo "${v}" ;;
    esac
}
