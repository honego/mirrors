#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 honeok <i@honeok.com>

set -Eeuo pipefail

_red() {
    printf "\033[31m%b\033[0m\n" "$*"
}

_err_msg() {
    printf "\033[41m\033[1mError\033[0m %b\n" "$*"
}

_log() {
    printf '%s [%s] %s\n' "$(date +"%F %T")" "$(basename "$0")" "$*"
}

# 各变量默认值
PROJECT_TOP="$(git rev-parse --show-toplevel 2> /dev/null)"
MANIFEST_FILE="$PROJECT_TOP/manifest.json"
ITEM_COUNT="$(jq '.items | length' "$MANIFEST_FILE")"

die() {
    _err_msg >&2 "$(_red "$@")"
    exit 1
}

curl() {
    local rc

    # 添加 --fail 不然404退出码也为0
    # 32位cygwin已停止更新 证书可能有问题 添加 --insecure
    # centos7 curl 不支持 --retry-connrefused --retry-all-errors 因此手动 retry
    for ((i = 1; i <= 5; i++)); do
        command curl --connect-timeout 10 --fail --insecure "$@"
        rc="$?"
        if [ "$rc" -eq 0 ]; then
            return
        else
            # 403 404 错误或达到重试次数
            if [ "$rc" -eq 22 ] || [ "$i" -eq 5 ]; then
                return "$rc"
            fi
            sleep 1
        fi
    done
}

main() {
    pushd "$PROJECT_TOP" || exit 1
    for i in $(seq 0 $((ITEM_COUNT - 1))); do
        item_name="$(jq -er ".items[$i].name" "$MANIFEST_FILE")"     # 文件名
        item_source="$(jq -er ".items[$i].source" "$MANIFEST_FILE")" # 上游地址
        item_path="$(jq -er ".items[$i].path" "$MANIFEST_FILE")"     # 保存目录

        # 拼接目标路径 目标文件名
        dest_dir="$PROJECT_TOP/$item_path"      # $PROJECT_TOP/gradle
        dest_file="$dest_dir/$item_name"        # $PROJECT_TOP/gradle/gradlew
        tmp_file="$dest_file.tmp"               # $PROJECT_TOP/gradle/gradlew.tmp
        dest_sha256_file="$dest_file.sha256sum" # $PROJECT_TOP/gradle/gradlew.sha256sum

        # 目标文件夹不存在则创建
        [ -d "$dest_dir" ] || mkdir -p "$dest_dir"

        _log "Sync $item_path/$item_name From $item_source"

        curl -Ls "$item_source" -o "$tmp_file"

        # 计算新下载文件的 sha256
        tmp_sha256="$(sha256sum "$tmp_file" | awk '{print $1}')"

        # 如果正式文件已存在就计算 sha256
        if [ -f "$dest_file" ]; then
            old_sha256="$(sha256sum "$dest_file" | awk '{print $1}')"
        else
            old_sha256=""
        fi

        # 对比哈希并更新文件
        if [ "$tmp_sha256" = "$old_sha256" ]; then
            rm -f "$tmp_file"
            _log "Unchanged $item_path/$item_name"
        else
            mv -f "$tmp_file" "$dest_file"
            printf '%s %s\n' "$tmp_sha256" "$item_name" > "$dest_sha256_file"
            _log "Updated $item_path/$item_name"
        fi
    done
    popd
}

main
