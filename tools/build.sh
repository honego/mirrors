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
    local i rc

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

sync_file() {
    local dest_dir dest_file dest_name dest_sha256_file item_name item_path item_source old_sha256 tmp_file tmp_sha256

    item_name="$1"
    item_source="$2"
    item_path="$3"

    # 拼接目标路径 目标文件名
    dest_file="$PROJECT_TOP/$item_path"     # $PROJECT_TOP/gradle/gradlew
    dest_dir="$(dirname "$dest_file")"      # $PROJECT_TOP/gradle
    dest_name="$(basename "$dest_file")"    # gradlew
    tmp_file="$dest_file.tmp"               # $PROJECT_TOP/gradle/gradlew.tmp
    dest_sha256_file="$dest_file.sha256sum" # $PROJECT_TOP/gradle/gradlew.sha256sum

    # 目标文件夹不存在则创建
    [ -d "$dest_dir" ] || mkdir -p "$dest_dir"

    _log "Sync $item_name $item_path From $item_source"

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
        _log "Unchanged $item_name $item_path"
    else
        mv -f "$tmp_file" "$dest_file"
        printf '%s %s\n' "$tmp_sha256" "$dest_name" > "$dest_sha256_file"
        _log "Updated $item_name $item_path"
    fi
}

sync_repository() {
    local dest_dir item_name item_path item_source tmp_dir worktree

    item_name="$1"
    item_source="$2"
    item_path="$3"

    # 拼接存储库保存目录
    dest_dir="$PROJECT_TOP/$item_path" # $PROJECT_TOP/acme.sh

    # 目标文件夹不存在则创建
    [ -d "$dest_dir" ] || mkdir -p "$dest_dir"

    # 克隆临时存储库
    tmp_dir="$(mktemp -d "$PROJECT_TOP/.repo-sync.XXXXXX")"
    worktree="$tmp_dir/worktree"
    _log "Sync $item_name $item_path From $item_source"
    git clone --depth 1 "$item_source" "$worktree"

    # 同步存储库文件
    rsync -a --delete --exclude ".git/" "$worktree/" "$dest_dir/"
    rm -rf "$tmp_dir"
    _log "Updated $item_name $item_path"
}

main() {
    local item_is_repository item_name item_path item_path_count item_path_type
    local item_source item_source_count item_source_type i j

    pushd "$PROJECT_TOP" || exit 1
    for i in $(seq 0 $((ITEM_COUNT - 1))); do
        item_name="$(jq -r ".items[$i].name // \"item-$i\"" "$MANIFEST_FILE")"   # 文件名
        item_source_type="$(jq -er ".items[$i].source | type" "$MANIFEST_FILE")" # 上游地址类型
        item_path_type="$(jq -er ".items[$i].path | type" "$MANIFEST_FILE")"     # 保存路径类型
        item_is_repository="$(
            jq -r \
                "(.items[$i].isRepository // false) as \$isRepository |
                if (\$isRepository | type) == \"boolean\" then \$isRepository else \"invalid\" end" \
                "$MANIFEST_FILE"
        )" # 是否为存储库

        if [ "$item_is_repository" = "invalid" ]; then
            die "Item isRepository must be a boolean"
        fi

        if [ "$item_is_repository" = "true" ]; then
            if [ "$item_source_type" != "string" ] || [ "$item_path_type" != "string" ]; then
                die "Repository item source and path must be strings"
            fi

            item_source="$(jq -er ".items[$i].source" "$MANIFEST_FILE")" # 上游地址
            item_path="$(jq -er ".items[$i].path" "$MANIFEST_FILE")"     # 保存目录
            sync_repository "$item_name" "$item_source" "$item_path"
            continue
        fi

        if [ "$item_source_type" = "string" ] && [ "$item_path_type" = "string" ]; then
            item_source="$(jq -er ".items[$i].source" "$MANIFEST_FILE")" # 上游地址
            item_path="$(jq -er ".items[$i].path" "$MANIFEST_FILE")"     # 保存路径
            sync_file "$item_name" "$item_source" "$item_path"
            continue
        fi

        if [ "$item_source_type" = "array" ] && [ "$item_path_type" = "array" ]; then
            item_source_count="$(jq -er ".items[$i].source | length" "$MANIFEST_FILE")"
            item_path_count="$(jq -er ".items[$i].path | length" "$MANIFEST_FILE")"
            if [ "$item_source_count" -ne "$item_path_count" ]; then
                die "Item source and path array length mismatch"
            fi

            for j in $(seq 0 $((item_source_count - 1))); do
                item_source="$(jq -er ".items[$i].source[$j]" "$MANIFEST_FILE")" # 上游地址
                item_path="$(jq -er ".items[$i].path[$j]" "$MANIFEST_FILE")"     # 保存路径
                sync_file "$item_name" "$item_source" "$item_path"
            done
            continue
        fi

        die "Item source and path must both be strings or arrays"
    done
    popd
}

main
