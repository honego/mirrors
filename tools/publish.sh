#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 honeok <i@honeok.com>

set -Eexuo pipefail

_log() {
    printf '%s [%s] %s\n' "$(date +"%F %T")" "$(basename "$0")" "$*"
}

PROJECT_TOP="$(git rev-parse --show-toplevel 2> /dev/null)"
pushd "$PROJECT_TOP" || exit 1

# 准备发布目录
rm -rf publish > /dev/null 2>&1 || true
mkdir -p publish > /dev/null 2>&1

# 同步发布文件
rsync -av ./ publish/ \
    --exclude ".*" \
    --exclude "*.json" \
    --exclude "tools/" \
    --exclude "templates/"

# 列出发布文件
find publish -maxdepth 4 -type f | sort

# 写入 github actions 输出变量函数
github_output() {
    local k v

    k="$1"
    v="$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "$k=$v" >> "$GITHUB_OUTPUT"
    fi
}

if [ "${PUBLISH_RELEASE_BRANCH:-false}" != "true" ]; then
    _log "Skip publish to release branch"
    github_output "release_changed" "false"
    exit 0
fi

_log "Publish to release branch"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
rm -rf release-worktree 2> /dev/null || true # 确保工作树干净
git fetch origin release || true             # 尝试拉取远程 release 分支

if git show-ref --verify --quiet refs/remotes/origin/release; then
    git worktree add -B release release-worktree origin/release # 如果远程已经有 release 分支就基于它创建本地 worktree
else
    git worktree add --detach release-worktree            # 如果远程还没有 release 分支则创建一个临时 worktree
    git -C release-worktree checkout --orphan release     # 在 worktree 里创建一个全新的 release 分支不继承当前分支历史
    git -C release-worktree rm -rf . 2> /dev/null || true # 清空新分支里的默认文件
fi

rsync -av --delete --exclude ".git" publish/ release-worktree/ # 将发布目录同步到 release-worktree 工作树

# 将 release-worktree 里的所有变更加入暂存区
git -C release-worktree add -A

# 除 index.html 以外没有额外变更就跳过发布
if git -C release-worktree diff --cached --quiet -- . ":(exclude)index.html"; then
    _log "No release changes"
    github_output "release_changed" "false"
    exit 0
fi

git -C release-worktree commit --signoff --no-verify -m "deploy: update mirror assets [skip ci]" # 提交 release-worktree 里的发布文件变更
git -C release-worktree push origin release                                                      # 将本地 release 分支推送到远程 release 分支
github_output "release_changed" "true"
popd
