#!/usr/bin/env bash
set -euo pipefail

merge_package() {
    local branch="$1"; local repo="$2"; local target_dir="$3"; shift 3
    local rootdir="$(pwd)"; local localdir="$target_dir"; mkdir -p "$localdir"
    local tmpdir="$(mktemp -d)"
    
    echo "  [稀疏提取] $(basename "$repo") -> $target_dir"
    git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$repo" "$tmpdir" >/dev/null 2>&1
    cd "$tmpdir" && git sparse-checkout init --cone && git sparse-checkout set "$@"
    for folder in "$@"; do
        local dest="$rootdir/$localdir/$(basename "$folder")"
        rm -rf "$dest"; mv -f "$folder" "$dest"
    done
    cd "$rootdir"; rm -rf "$tmpdir"
}

mkdir -p package/custom

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS='|' read -ra parts <<< "$line"
    type="${parts[0]}"
    if [ "$type" == "full" ]; then
        echo "  [全量] ${parts[1]}"
        # ★ 加一个 || echo 兜底，就算克隆失败也不会中断脚本
        git clone --depth 1 -b "${parts[3]}" "${parts[2]}" "package/custom/${parts[1]}" || echo "  ⚠️ 克隆 ${parts[1]} 失败，跳过！"
    elif [ "$type" == "sparse" ]; then
        # ★ 同样加一个兜底
        merge_package "${parts[3]}" "${parts[2]}" "${parts[1]}" "${parts[@]:4}" || echo "  ⚠️ 提取 ${parts[1]} 失败，跳过！"
    fi
done < packages.list

find package/custom -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
echo "==> 源码准备完毕！"