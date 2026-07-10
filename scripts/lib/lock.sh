#!/usr/bin/env bash
# 并发锁：优先 flock(1)（内核在进程退出时自动释放），无 flock 时回退 mkdir 原子锁。
# 依赖入口脚本声明的共享状态：LOCK_PATH / LOCK_ACQUIRED / PLATFORM。

release_lock() {
    if ((LOCK_ACQUIRED == 1)) && [[ -n "$LOCK_PATH" ]]; then
        rm -rf -- "$LOCK_PATH" 2>/dev/null || true
        LOCK_ACQUIRED=0
    fi
}

handle_lock_signal() {
    local signal_name="$1"
    release_lock
    trap - "$signal_name"
    kill -s "$signal_name" "$$"
}

acquire_lock() {
    local lock_dir
    lock_dir="$(prepare_lock_directory)" || return 1
    umask 077
    LOCK_PATH="$lock_dir/upkeep-${UID}.lock"
    if command -v flock >/dev/null 2>&1; then
        acquire_lock_with_flock
    else
        acquire_lock_with_mkdir
    fi
}

# 优先 flock(1)（Linux 自带）：进程无论如何退出，内核都会释放锁，不会残留。
acquire_lock_with_flock() {
    if [[ -d "$LOCK_PATH" ]]; then
        printf '错误：发现残留的目录锁：%s（确认无更新进程后可手动删除）。\n' "$LOCK_PATH" >&2
        return 1
    fi
    if [[ -e "$LOCK_PATH" && ( ! -f "$LOCK_PATH" || -L "$LOCK_PATH" || ! -O "$LOCK_PATH" ) ]]; then
        printf '错误：锁文件不安全：%s\n' "$LOCK_PATH" >&2
        return 1
    fi
    exec 9<>"$LOCK_PATH" || return 1
    if ! flock -n 9; then
        printf '错误：已有更新任务正在运行（锁：%s）。\n' "$LOCK_PATH" >&2
        return 1
    fi
}

# macOS 无 flock(1) 时回退 mkdir 原子锁：PID 陈锁自愈 + 信号清理；kill -9 仍可能残留，报错给出路径。
acquire_lock_with_mkdir() {
    if ! mkdir -- "$LOCK_PATH" 2>/dev/null && ! break_stale_lock; then
        printf '错误：已有更新任务正在运行（锁：%s，确认无更新进程后可手动删除）。\n' "$LOCK_PATH" >&2
        return 1
    fi
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"$LOCK_PATH/pid" 2>/dev/null || true
    trap release_lock EXIT
    trap 'handle_lock_signal INT' INT
    trap 'handle_lock_signal TERM' TERM
    trap 'handle_lock_signal HUP' HUP
}

# 仅当锁内记录的 PID 确认已退出才回收；缺 PID 文件按持有中处理，避免误抢刚创建的锁。
break_stale_lock() {
    local owner_pid=''
    if [[ -f "$LOCK_PATH/pid" ]]; then
        IFS= read -r owner_pid <"$LOCK_PATH/pid" || owner_pid=''
    fi
    [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
    if kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi
    printf '警告：清理残留锁（原进程 %s 已退出）：%s\n' "$owner_pid" "$LOCK_PATH" >&2
    rm -rf -- "$LOCK_PATH" 2>/dev/null || return 1
    mkdir -- "$LOCK_PATH" 2>/dev/null
}

prepare_lock_directory() {
    local lock_dir
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        lock_dir="$XDG_RUNTIME_DIR"
    elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
        lock_dir="$XDG_STATE_HOME/upkeep"
    elif [[ -n "${HOME:-}" ]]; then
        lock_dir="$HOME/.local/state/upkeep"
    else
        printf '错误：无法确定安全的锁目录。\n' >&2
        return 1
    fi

    if [[ "$lock_dir" != /* ]]; then
        printf '错误：锁目录必须使用绝对路径：%s\n' "$lock_dir" >&2
        return 1
    fi

    if [[ ! -e "$lock_dir" ]]; then
        (umask 077 && mkdir -p -- "$lock_dir") || return 1
        chmod 700 "$lock_dir" || return 1
    fi
    validate_lock_directory "$lock_dir" || return 1
    printf '%s\n' "$lock_dir"
}

validate_lock_directory() {
    local lock_dir="$1"
    local mode
    if [[ ! -d "$lock_dir" || -L "$lock_dir" || ! -O "$lock_dir" || ! -w "$lock_dir" ]]; then
        printf '错误：锁目录必须由当前用户独占：%s\n' "$lock_dir" >&2
        return 1
    fi
    if [[ "$PLATFORM" == 'macos' ]]; then
        mode="$(stat -f '%Lp' -- "$lock_dir")" || {
            printf '错误：无法读取锁目录权限：%s\n' "$lock_dir" >&2
            return 1
        }
    elif ! mode="$(stat -c '%a' -- "$lock_dir")"; then
        printf '错误：无法读取锁目录权限：%s\n' "$lock_dir" >&2
        return 1
    fi
    if (((8#$mode & 8#077) != 0)); then
        printf '错误：锁目录权限过宽：%s（%s）\n' "$lock_dir" "$mode" >&2
        return 1
    fi
}
