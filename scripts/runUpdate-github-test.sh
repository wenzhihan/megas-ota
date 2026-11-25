#!/bin/bash

# 脚本名称: runUpdate-github-test.sh
# 功能描述: 升级链路验证版（GitHub 作为固件源，实际升级动作全部注释，DRY-RUN）
# 基    于: E:\mega\upgrade\git\runUpdate.sh (md5 311c4ce6805c23cebeabbbc8bc52a412)
#
# 与正式版的差异：
#   1. DOWNLOAD_URL / URL2 / URL3 全部指向 GitHub 公开仓库 wenzhihan/megas-ota
#   2. 增加 .sha256 校验（仓库里每个包都带同名 .sha256）
#   3. 【实际升级内容全部注释】kill 进程 / 备份 Core / 覆盖 /home/cat/pub / chmod / ./Core -v / reboot
#      -> 只做「下载 + 解压 + 载荷识别 + 校验 + 打印将要做什么」
#
# 用法: sudo ./runUpdate-github-test.sh [dev] [megaS] <version> <choice>

LOCK_FILE="/tmp/runUpdate.lock"
TOTAL_STEPS=7

DEV_MODE=0        # dev 模式：强制使用 DOWNLOAD_URL3（jsDelivr 镜像）
MEGAS_MODE=0      # megaS 模式：使用 megaS 专用固件包名

while [ "$#" -gt 0 ]; do
    case "$1" in
        dev)
            DEV_MODE=1
            shift
            ;;
        megaS)
            MEGAS_MODE=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 2 ]; then
    echo "Usage: sudo $0 [dev] [megaS] <version> <choice: 0-null, 1-soc, 2-mcu, 3-soc+mcu>"
    exit 1
fi

VERSION="$1"
CHOICE="$2"

# ---------------------------------------------------------------------------
# 固件源地址：全部改成刚建好的 GitHub 公开仓库
#   包路径约定: packages/v<version>/<ZIP_NAME>
#   直链模板  : https://raw.githubusercontent.com/wenzhihan/megas-ota/main/packages/v<version>/<ZIP_NAME>
# ---------------------------------------------------------------------------
GH_OWNER="wenzhihan"
GH_REPO="megas-ota"
GH_BRANCH="main"
PKG_DIR="packages/v$VERSION"

if [ "$MEGAS_MODE" -eq 1 ]; then
    echo "[runUpdate] Target product: MegaS"
    ZIP_NAME="Firmware-MegaS-$VERSION.zip"
else
    echo "[runUpdate] Target product: Mega"
    ZIP_NAME="Firmware-$VERSION.zip"
fi

DOWNLOAD_URL="https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/$GH_BRANCH/$PKG_DIR/$ZIP_NAME"   # GitHub raw（主源）
DOWNLOAD_URL2="https://github.com/$GH_OWNER/$GH_REPO/raw/$GH_BRANCH/$PKG_DIR/$ZIP_NAME"             # github.com /raw（同源备用，302 跟随）
DOWNLOAD_URL3="https://cdn.jsdelivr.net/gh/$GH_OWNER/$GH_REPO@$GH_BRANCH/$PKG_DIR/$ZIP_NAME"        # jsDelivr CDN（dev 模式，注意单文件 20MB 限制）

TARGET_DIR="/home/cat/pub"
TMP_DIR="/tmp/update_tmp"
ZIP_PATH="$TMP_DIR/$ZIP_NAME"
DISCOVER_URL="http://127.0.0.1:8080/discover"
SELECTED_URL=""

echo "[runUpdate] Firmware source : $DOWNLOAD_URL"
echo "[runUpdate] Mode            : DRY-RUN (实际升级动作已注释，不会改动 $TARGET_DIR，不会重启)"

# 目录同步
sync_copy() {
    local src="$1"
    local dst="$2"
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$src"/ "$dst"/
    else
        (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -)
    fi
}

show_progress() {
    local step=$1
    local msg=$2
    local percent=$(( step * 100 / TOTAL_STEPS ))
    echo "Progress: ${percent}% - ${msg}"
}

create_or_replace_lock() {
    echo "$$" > "$LOCK_FILE"
}

check_running_instance_and_lock() {
    if [ -f "$LOCK_FILE" ]; then
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)

        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "An update is already in progress (PID: $OLD_PID). Please wait until it finishes."
            exit 1
        else
            echo "Stale lock file found. Removing it now."
            rm -f "$LOCK_FILE"
        fi
    fi

    create_or_replace_lock
}

# ---------------------------------------------------------------------------
# 【已注释】真实升级第 1 步：停服务、杀进程
# ---------------------------------------------------------------------------
kill_old_processes() {
    echo "[DRY-RUN] 跳过 kill_old_processes()：不再执行 systemctl stop ntmega / kill Core 等"
    # echo "Stopping ntmega service..."
    # sudo systemctl stop ntmega
    # for PROC in lbGcodeFifo Core Device webCamera; do
    #     PID=$(pidof $PROC)
    #     if [ ! -z "$PID" ]; then
    #         echo "Killing process: $PROC (PID: $PID)"
    #         sudo kill -9 $PID
    #     fi
    # done
}

measure_url_time_retry() {
    local url="$1"
    local retry=3
    local best_time=""
    local attempt_time=""

    for ((i=1; i<=retry; i++)); do
        if [ "$i" -eq 1 ]; then
            connect_timeout=3
            max_time=7
        elif [ "$i" -eq 2 ]; then
            connect_timeout=5
            max_time=10
        else
            connect_timeout=6
            max_time=12
        fi

        attempt_time=$(curl -L -r 0-1023 -o /dev/null \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            --silent --show-error --fail -w "%{time_total}" "$url" 2>/dev/null)

        if [ -n "$attempt_time" ]; then
            if [ -z "$best_time" ] || awk "BEGIN {exit !($attempt_time < $best_time)}"; then
                best_time="$attempt_time"
            fi
        fi

        sleep 1
    done

    echo "$best_time"
}

compare_download_speed() {
    local best_url=""
    local best_time=""
    local current_time=""
    local url=""

    for url in "$DOWNLOAD_URL" "$DOWNLOAD_URL2"; do
        echo "Checking URL: $url"
        current_time=$(measure_url_time_retry "$url")

        if [ -n "$current_time" ]; then
            echo "URL is downloadable, best time = ${current_time}s"
            if [ -z "$best_time" ] || awk "BEGIN {exit !($current_time < $best_time)}"; then
                best_time="$current_time"
                best_url="$url"
            fi
        else
            echo "URL is NOT downloadable"
        fi
    done

    if [ -n "$best_url" ]; then
        SELECTED_URL="$best_url"
        echo "Selected fastest URL: $SELECTED_URL (time=${best_time}s)"
        return 0
    fi

    echo "Progress: -2 - All download sources are invalid after retries."
    cleanup_and_exit 1
}

# ---------------------------------------------------------------------------
# 【已注释】真实升级主体：备份 Core -> 覆盖 /home/cat/pub -> chmod -> ./Core -v
# 现在只做载荷体检，不动设备。
# ---------------------------------------------------------------------------
run_soc_update() {
    if [ -z "${PAYLOAD_ROOT:-}" ] || [ ! -d "$PAYLOAD_ROOT" ]; then
        echo "Progress: -2 - Payload root not found. (PAYLOAD_ROOT=$PAYLOAD_ROOT)"
        return 1
    fi

    echo "================= DRY-RUN 载荷体检 ================="
    echo "payload root : $PAYLOAD_ROOT"
    echo "payload files:"
    find "$PAYLOAD_ROOT" -maxdepth 2 -type f -printf '   %-40p %8s B\n' 2>/dev/null || \
        ls -l "$PAYLOAD_ROOT"
    echo "---------------------------------------------------"
    echo "目标目录 $TARGET_DIR 现状（不会改动）:"
    if [ -f "$TARGET_DIR/Core" ]; then
        echo "   Core 存在  md5=$(md5sum "$TARGET_DIR/Core" 2>/dev/null | awk '{print $1}')"
    else
        echo "   Core 不存在"
    fi
    echo "---------------------------------------------------"
    echo "真实升级时本应执行、现已被注释的动作:"
    echo "   [1] kill_old_processes        (systemctl stop ntmega; kill lbGcodeFifo/Core/Device/webCamera)"
    echo "   [2] mv $TARGET_DIR/Core -> Core.bak"
    echo "   [3] sync_copy \$PAYLOAD_ROOT -> $TARGET_DIR   (覆盖 Core 与全部运行时文件)"
    echo "   [4] chmod +x $TARGET_DIR/Core"
    echo "   [5] ./Core -v"
    echo "   [6] reboot"
    echo "==================================================="

    # ---- 以下为原始真实升级逻辑，全部注释保留 ----
    # local STAGE_DIR="$TMP_DIR/stage"
    # rm -rf "$STAGE_DIR"
    # mkdir -p "$STAGE_DIR"
    #
    # sync_copy "$PAYLOAD_ROOT" "$STAGE_DIR"
    #
    # if [ -f "$STAGE_DIR/newCore" ]; then
    #     mv -f "$STAGE_DIR/newCore" "$STAGE_DIR/Core"
    # fi
    #
    # if [ ! -f "$STAGE_DIR/Core" ]; then
    #     echo "Progress: -2 - Neither newCore nor Core found in payload."
    #     return 1
    # fi
    #
    # kill_old_processes
    #
    # if [ -f "$TARGET_DIR/Core" ]; then
    #     sudo mv -f "$TARGET_DIR/Core" "$TARGET_DIR/Core.bak"
    # fi
    #
    # sync_copy "$STAGE_DIR" "$TARGET_DIR"
    #
    # sudo chmod +x "$TARGET_DIR/Core"
    #
    # ( cd "$TARGET_DIR" && \
    #   env LD_LIBRARY_PATH=$TARGET_DIR:$LD_LIBRARY_PATH \
    #       QT_QPA_PLATFORM_PLUGIN_PATH=$TARGET_DIR/plugins \
    #       QT_DEBUG_PLUGINS=0 \
    #       ./Core -v ) || true

    return 0
}

run_mcu_update() {
    echo "[DRY-RUN] run_mcu_update() 未实现（正式版同样为空）"
}

cleanup_and_exit() {
    local code=$1
    local reboot_flag=$2
    local children
    children=$(pgrep -P $$)
    for child in $children; do
        echo "Killing child PID $child"
        kill -9 $child 2>/dev/null
    done
    rm -f "$LOCK_FILE"
    if [ "$code" -eq 0 ] && [ "$reboot_flag" = "reboot" ]; then
        # ---- 【已注释】真实升级结束后会重启 ----
        # echo "Rebooting now..."
        # sudo reboot
        echo "[DRY-RUN] 本应 reboot，已注释，保持设备在线"
        exit 0
    else
        exit "$code"
    fi
	trap 'cleanup_and_exit 1' INT TERM
}

# Step 0 - 启动锁机制
check_running_instance_and_lock

# Step 1 - 获取并比较当前版本
show_progress 1 "Getting current device version"
CURRENT_VER=$(curl -s "$DISCOVER_URL" | grep -oP '"binver"\s*:\s*"\K[^"]+')
if [ -n "$CURRENT_VER" ]; then
    echo "Current version: $CURRENT_VER, Target version: $VERSION"

    compare_versions() {
        IFS='.' read -ra v1 <<< "$1"
        IFS='.' read -ra v2 <<< "$2"
        local len=${#v1[@]}
        [ ${#v2[@]} -gt $len ] && len=${#v2[@]}
        for ((i=0; i<len; i++)); do
            local a=${v1[i]:-0}
            local b=${v2[i]:-0}
            if ((10#$a < 10#$b)); then return 0; elif ((10#$a > 10#$b)); then return 1; fi
        done
        return 1
    }

    compare_versions "$CURRENT_VER" "$VERSION"
    if [ $? -ne 0 ]; then
        echo "Current version is equal to or higher than target, no update needed."
        cleanup_and_exit 0
    else
        echo "Current version is lower than target, proceeding with update..."
    fi
else
    echo "Failed to retrieve current version, proceeding with update..."
fi

# Step 2 - 准备临时目录
show_progress 2 "Preparing temporary directory $TMP_DIR..."
sudo rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Step 3 - 选择下载源
if [ "$DEV_MODE" -eq 1 ]; then
    echo "Dev mode enabled: using DOWNLOAD_URL3 (jsDelivr) for download."
    SELECTED_URL="$DOWNLOAD_URL3"
else
    compare_download_speed
fi

# Step 4 - 下载 ZIP 包（28%~79%）
DOWNLOAD_START_PERCENT=28
DOWNLOAD_END_PERCENT=79
MAX_WAIT=60

echo "Progress: ${DOWNLOAD_START_PERCENT}% - Starting download for firmware version $VERSION from $SELECTED_URL..."
sudo wget -L --no-check-certificate --progress=dot:giga --timeout=1800 --connect-timeout=120 --tries=5 -O "$ZIP_PATH" "$SELECTED_URL" > "$TMP_DIR/wget.log" 2>&1 &
WGET_PID=$!

i=0
while kill -0 $WGET_PID 2>/dev/null; do
    CURRENT_PERCENT=$(( DOWNLOAD_START_PERCENT + i * (DOWNLOAD_END_PERCENT - DOWNLOAD_START_PERCENT) / MAX_WAIT ))
    [ "$CURRENT_PERCENT" -gt "$DOWNLOAD_END_PERCENT" ] && CURRENT_PERCENT=$DOWNLOAD_END_PERCENT
    echo "Progress: ${CURRENT_PERCENT}% - Downloading firmware..."
    sleep 1
    ((i++))
done

wait $WGET_PID
if [ $? -ne 0 ]; then
    echo "Progress: -2 - Download failed or timed out. Check $TMP_DIR/wget.log for details."
    cleanup_and_exit 1
fi

ZIP_SIZE=$(stat -c %s "$ZIP_PATH" 2>/dev/null || echo 0)
echo "Progress: ${DOWNLOAD_END_PERCENT}% - Download completed. (${ZIP_SIZE} bytes)"

# Step 4.5 - 校验 sha256（仓库每个包都带 .sha256）
echo "Verifying sha256 against $SELECTED_URL.sha256 ..."
EXPECT_SHA=$(curl -sL --max-time 30 "$SELECTED_URL.sha256" | awk '{print $1}' | tr -d '\r\n')
ACTUAL_SHA=$(sha256sum "$ZIP_PATH" | awk '{print $1}')
echo "   expect: ${EXPECT_SHA:-<none>}"
echo "   actual: $ACTUAL_SHA"
if [ -z "$EXPECT_SHA" ]; then
    echo "WARNING: .sha256 not available on server, skip integrity check."
elif [ "$EXPECT_SHA" != "$ACTUAL_SHA" ]; then
    echo "Progress: -2 - sha256 mismatch, abort."
    cleanup_and_exit 1
else
    echo "sha256 OK."
fi

# Step 5 - 解压 ZIP（80%~89%）
EXTRACT_START_PERCENT=80
EXTRACT_END_PERCENT=89
EXTRACT_DURATION=5
UNZIP_DIR="$TMP_DIR/unzip"

echo "Progress: ${EXTRACT_START_PERCENT}% - Extracting files to temporary directory"
rm -rf "$UNZIP_DIR"
mkdir -p "$UNZIP_DIR"

unzip -o "$ZIP_PATH" -d "$UNZIP_DIR" > "$TMP_DIR/unzip.log" 2>&1 &
UNZIP_PID=$!

i=0
while kill -0 "$UNZIP_PID" 2>/dev/null; do
    CURRENT_PERCENT=$(( EXTRACT_START_PERCENT + i * (EXTRACT_END_PERCENT - EXTRACT_START_PERCENT) / EXTRACT_DURATION ))
    [ "$CURRENT_PERCENT" -gt "$EXTRACT_END_PERCENT" ] && CURRENT_PERCENT=$EXTRACT_END_PERCENT
    echo "Progress: ${CURRENT_PERCENT}% - Extracting..."
    sleep 1
    ((i++))
done

wait "$UNZIP_PID" || { echo "Progress: -2 - Extraction failed, exiting update"; cleanup_and_exit 1; }

# 自动识别载荷根目录
if [ "$(find "$UNZIP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] && \
   [ "$(find "$UNZIP_DIR" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
    PAYLOAD_ROOT="$(find "$UNZIP_DIR" -mindepth 1 -maxdepth 1 -type d)"
else
    PAYLOAD_ROOT="$UNZIP_DIR"
fi

echo "Progress: ${EXTRACT_END_PERCENT}% - Extraction complete (payload root: $PAYLOAD_ROOT)."

# Step 6 & Step 7 - 预留更新进度（90%~99%）
UPDATE_START_PERCENT=90
UPDATE_END_PERCENT=99
UPDATE_DURATION=3

echo "Progress: ${UPDATE_START_PERCENT}% - Preparing to apply update (DRY-RUN)..."

i=0
while [ $i -le $UPDATE_DURATION ]; do
    CURRENT_PERCENT=$(( UPDATE_START_PERCENT + i * (UPDATE_END_PERCENT - UPDATE_START_PERCENT) / UPDATE_DURATION ))
    [ "$CURRENT_PERCENT" -gt "$UPDATE_END_PERCENT" ] && CURRENT_PERCENT=$UPDATE_END_PERCENT
    echo "Progress: ${CURRENT_PERCENT}% - DRY-RUN, nothing will be written to $TARGET_DIR..."
    sleep 1
    ((i++))
done

echo "[runUpdate] DRY-RUN start: only inspect payload, real update is commented out."

case "$CHOICE" in
    0|1|2|3)
        run_soc_update
        ;;
    *)
        echo "Unknown choice: $CHOICE, default to SOC update"
        run_soc_update
        ;;
esac

if [ $? -ne 0 ]; then
    echo "Progress: -2 - Update procedure failed, exiting."
    cleanup_and_exit 1
fi

echo "Progress: 100% - DRY-RUN finished. Device left untouched (no Core replacement, no reboot)."

# ---------------------------------------------------------------------------
# 【已注释】真实升级收尾：修权限 + 重启
# ---------------------------------------------------------------------------
# if [ -d "$TARGET_DIR" ]; then
#     echo "Fixing owner and permissions under $TARGET_DIR ..."
#     sudo chown -R cat:cat "$TARGET_DIR" || true
#     sudo chmod +x "$TARGET_DIR"/* 2>/dev/null || true
# fi
#
# cleanup_and_exit 0 reboot

cleanup_and_exit 0 noreboot
