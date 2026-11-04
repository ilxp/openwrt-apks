#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 核心函数：稀疏克隆（提取大仓库中的特定文件夹）
# ==============================================================================
merge_package() {
    local branch="$1"
    local repo="$2"
    local target_dir="$3"
    shift 3

    local rootdir="$(pwd)"
    local localdir="$target_dir"
    mkdir -p "$localdir"

    local tmpdir
    tmpdir="$(mktemp -d)" || return 1

    local show=""
    for p in "$@"; do show="${show:+$show }$(basename "$p")"; done
    echo "  [稀疏] $(basename "$repo") -> $target_dir/$show"

    if ! git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$repo" "$tmpdir" >/dev/null 2>&1; then
        echo "错误: 无法克隆仓库 $repo" >&2
        rm -rf "$tmpdir"
        return 1
    fi

    cd "$tmpdir" || { rm -rf "$tmpdir"; return 1; }
    git sparse-checkout init --cone >/dev/null 2>&1
    git sparse-checkout set "$@" >/dev/null 2>&1

    for folder in "$@"; do
        local dest="$rootdir/$localdir/$(basename "$folder")"
        rm -rf "$dest"
        mv -f "$folder" "$dest"
    done

    cd "$rootdir" || return 1
    rm -rf "$tmpdir"
    return 0
}

# ==============================================================================
# 1. 环境准备 (ImmortalWrt SDK)
# ==============================================================================
SDK_VER="25.12.2"
SDK_FILE="immortalwrt-sdk-${SDK_VER}-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_URL="https://downloads.immortalwrt.org/releases/${SDK_VER}/targets/x86/64/${SDK_FILE}"

echo "==> 下载 SDK: ${SDK_VER}..."
wget -q "$SDK_URL" -O sdk.tar.zst
tar --zstd -xf sdk.tar.zst
mv immortalwrt-sdk-* sdk
cd sdk

# ==============================================================================
# 2. 更新 Feeds (基础依赖)
# ==============================================================================
echo "==> 更新 Feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# ==============================================================================
# 3. 解析 packages.list 并拉取源码
# ==============================================================================
echo "==> 开始解析 packages.list 并拉取源码..."
mkdir -p package/custom

# 确保文件存在
if [ ! -f ../packages.list ]; then
    echo "错误: 找不到 ../packages.list"
    exit 1
fi

# 过滤空行和注释行，开始循环
grep -vE '^\s*(#|$)' ../packages.list | while IFS='|' read -r type arg1 arg2 arg3 rest; do
    if [ "$type" == "full" ]; then
        # 格式: full|目录名|git地址|分支
        echo "  [全量] $arg1"
        git clone --depth 1 -b "$arg3" "$arg2" "package/custom/$arg1" || echo "  克隆 $arg1 失败！"
        
    elif [ "$type" == "sparse" ]; then
        # 格式: sparse|目标目录|git地址|分支|路径1|路径2...
        # 注意：read 把剩下的字段全吞进 rest 了，但我们需要重新组装
        # 为了简单，直接用原生的 read -a 数组重构
        :
    fi
done

# 因为 Bash 的 read 限制，处理 sparse 多路径比较复杂，我们重写这部分逻辑：
while IFS= read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" == \#* ]] && continue
    
    # 以 | 分割成数组
    IFS='|' read -ra parts <<< "$line"
    type="${parts[0]}"

    if [ "$type" == "full" ]; then
        dir="${parts[1]}"
        url="${parts[2]}"
        branch="${parts[3]}"
        echo "  [全量] $dir"
        git clone --depth 1 -b "$branch" "$url" "package/custom/$dir" || echo "  克隆 $dir 失败！"

    elif [ "$type" == "sparse" ]; then
        target_dir="${parts[1]}"
        url="${parts[2]}"
        branch="${parts[3]}"
        # 获取剩下的所有路径
        paths=("${parts[@]:4}")
        merge_package "$branch" "$url" "$target_dir" "${paths[@]}"
    fi
done < ../packages.list

# 清理隐藏的 .git 减小体积
find package/custom -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

# ==============================================================================
# 4. 开始编译
# ==============================================================================
echo "==> 开始编译..."
make defconfig
# 编译 custom 目录下的所有包
make package/custom/compile V=s -j$(nproc) || true

# ==============================================================================
# 5. 收集 APK
# ==============================================================================
echo "==> 收集产物..."
mkdir -p ../output
find bin/packages -name "*.apk" -exec cp {} ../output/ \;

echo "==> 编译结束！共生成 $(ls -1 ../output/*.apk | wc -l) 个文件"
ls -lh ../output/
