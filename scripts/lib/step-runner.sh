#!/usr/bin/env bash
# 步骤编排原语：跳过标记、特权执行、单步运行与结果汇总。
# 依赖入口脚本声明的共享状态：RESULT_LABELS / RESULT_STATES / RESULT_DETAILS /
# FAILURE_COUNT / STEP_DETAIL / STEP_SKIPPED。

skip_step() {
    STEP_DETAIL="$1"
    STEP_SKIPPED=1
    return 0
}

run_with_sudo() {
    local executable="$1"
    if [[ "$executable" != /* || ! -x "$executable" ]]; then
        STEP_DETAIL="sudo 只接受已确认存在的绝对可执行路径：$executable"
        return 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        STEP_DETAIL='当前操作需要管理员权限，但未检测到 sudo'
        return 1
    fi
    sudo -- "$@"
}

run_step() {
    local label="$1"
    local function_name="$2"
    local status
    STEP_DETAIL=''
    STEP_SKIPPED=0
    printf '\n==> %s\n' "$label"
    "$function_name"
    status=$?

    RESULT_LABELS+=("$label")
    if ((STEP_SKIPPED == 1)); then
        RESULT_STATES+=('跳过')
    elif ((status == 0)); then
        RESULT_STATES+=('完成')
    else
        RESULT_STATES+=('失败')
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        [[ -n "$STEP_DETAIL" ]] || STEP_DETAIL="命令退出状态：$status"
    fi
    RESULT_DETAILS+=("$STEP_DETAIL")
}

print_summary() {
    local index detail
    printf '\n更新结果\n'
    for index in "${!RESULT_LABELS[@]}"; do
        detail="${RESULT_DETAILS[$index]}"
        printf '  %s：%s' "${RESULT_LABELS[$index]}" "${RESULT_STATES[$index]}"
        [[ -z "$detail" ]] || printf '（%s）' "$detail"
        printf '\n'
    done
}
