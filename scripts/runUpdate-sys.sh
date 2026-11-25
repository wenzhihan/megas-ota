#!/bin/sh
# =====================================================================
# MEGAS 系统升级入口（含重启）—— runUpdate-sys.sh
#
# 用法: sudo sh runUpdate-sys.sh [version] [--no-reboot]
#   默认 version=9.9.18；默认【会重启系统】
#
# 流程: 从 GitHub 拉包 -> sha256 校验 -> 解包 -> deploy_sys.sh --apply
#       -> 激活(systemd enable / nmcli reload) -> 延迟 3s 重启
#
# ★ 重启会断开 SSH，本脚本用 setsid 后台触发 reboot，
#   由上位机轮询设备重新上线并读取 /home/cat/rndis_upgrade_state 验收。
# =====================================================================
set -u

VER="${1:-9.9.21}"
NO_REBOOT=0
[ "${2:-}" = "--no-reboot" ] && NO_REBOOT=1

GH_OWNER=wenzhihan
GH_REPO=megas-ota
GH_BRANCH=main
PKG="Firmware-MegaS-$VER"
BASE="https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/$GH_BRANCH/packages/v$VER"
WORK=/tmp/rndis_upgrade
STATE=/home/cat/rndis_upgrade_state
LOG=$WORK/run.log

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "!! $*"; echo "STATUS=FAIL" >> "$STATE"; exit 1; }

# 提权
if [ "$(id -u)" = "0" ]; then
    SUDO=""
elif sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
else
    die "需要 root 或免密 sudo"
fi

BOOT_BEFORE=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
mkdir -p "$WORK" || die "无法创建 $WORK"
: > "$STATE"
echo "VERSION=$VER" >> "$STATE"
echo "BOOT_BEFORE=$BOOT_BEFORE" >> "$STATE"
echo "STARTED=$(date '+%F %T')" >> "$STATE"

# 重启后板子 RTC 可能回退到 2024（NTP 未同步），HTTPS 证书会判 "not yet valid"。
# 与 MDH 原版一致，必须 --no-check-certificate；并先等网络真正就绪。
log "== 1a. 等待网络就绪（GitHub raw）=="
i=0
while [ $i -lt 30 ]; do
    wget -q --spider --no-check-certificate --timeout=5 "$BASE/$PKG.zip.sha256" && break
    sleep 2; i=$((i+1))
done
[ "$i" -lt 30 ] || die "网络不可达（等了 60s）"

log "== 1. 下载 $PKG.zip =="
TS=$(date +%s)
wget -q --no-check-certificate --timeout=20 --tries=3 -O "$WORK/$PKG.zip" "$BASE/$PKG.zip?t=$TS" || die "下载失败"
wget -q --no-check-certificate --timeout=20 --tries=3 -O "$WORK/$PKG.zip.sha256" "$BASE/$PKG.zip.sha256?t=$TS" || die "sha256 下载失败"
log "   $(stat -c %s "$WORK/$PKG.zip") B"

log "== 2. sha256 校验 =="
EXPECT=$(awk '{print $1}' "$WORK/$PKG.zip.sha256" | tr -d '\r' | head -1)
ACTUAL=$(sha256sum "$WORK/$PKG.zip" | awk '{print $1}')
echo "SHA256=$ACTUAL" >> "$STATE"
[ "$EXPECT" = "$ACTUAL" ] || die "sha256 不一致: 期望=$EXPECT 实际=$ACTUAL"
log "   OK $ACTUAL"

log "== 3. 解包 =="
cd "$WORK" || die "cd $WORK"
rm -rf "$PKG"
unzip -q "$PKG.zip" || die "解包失败"
ROOT="$WORK/$PKG"
[ -f "$ROOT/deploy_sys.sh" ] || die "包内缺少 deploy_sys.sh"

log "== 4. 覆盖系统文件 (deploy_sys.sh --apply) =="
$SUDO sh "$ROOT/deploy_sys.sh" "$ROOT" --apply > "$WORK/deploy.log" 2>&1
DRC=$?
cat "$WORK/deploy.log"
[ "$DRC" -eq 0 ] || die "deploy_sys.sh 失败 rc=$DRC"
BACKUP=$(grep '备份目录:' "$WORK/deploy.log" | tail -1 | grep -o '/home/cat/pub/backup_sys/[0-9_]*' | head -1)
echo "BACKUP=$BACKUP" >> "$STATE"
[ -n "$BACKUP" ] || die "未找到备份目录"

log "== 5. 激活 RNDIS 环境 =="
$SUDO systemctl daemon-reload || die "daemon-reload 失败"
$SUDO systemctl enable mega-vnic.service >/dev/null 2>&1 || die "enable 失败"
$SUDO nmcli connection reload >/dev/null 2>&1 || log "  (nmcli reload 不可用，跳过)"
log "   enabled=$($SUDO systemctl is-enabled mega-vnic.service 2>/dev/null)"
echo "ENABLED=$($SUDO systemctl is-enabled mega-vnic.service 2>/dev/null)" >> "$STATE"

log "== 6. 校验已覆盖文件 =="
$SUDO sh "$ROOT/deploy_sys.sh" "$ROOT" --verify "$BACKUP" >> "$WORK/deploy.log" 2>&1
VRC=$?
[ "$VRC" -eq 0 ] || die "覆盖后 md5 校验失败，请用 --rollback $BACKUP 回退"
log "   md5 校验 OK"

echo "STATUS=DEPLOYED" >> "$STATE"

if [ "$NO_REBOOT" = "1" ]; then
    log "== --no-reboot：跳过重启 =="
    echo "REBOOT=SKIPPED" >> "$STATE"
    log "######## DONE ########"
    exit 0
fi

log "== 7. 3 秒后重启系统 =="
echo "REBOOT=SCHEDULED" >> "$STATE"
echo "SCHEDULED_AT=$(date '+%F %T')" >> "$STATE"
# 用 setsid 脱离当前 SSH 会话，保证 reboot 一定能发出去
setsid nohup sh -c "sleep 3; $SUDO systemctl reboot" > /dev/null 2>&1 < /dev/null &
log "######## DONE (reboot scheduled) ########"
exit 0
