#!/bin/sh
# =====================================================================
# MEGAS 系统文件覆盖式升级执行器（deploy_sys.sh）
#
# 用法:
#   sh deploy_sys.sh <payload_root>                # DRY-RUN（默认，绝不写文件、绝不重启）
#   sh deploy_sys.sh <payload_root> --apply        # 备份 + 原子覆盖 + md5 校验
#   sh deploy_sys.sh <payload_root> --rollback <backup_dir>   # 从备份整包回退
#   sh deploy_sys.sh <payload_root> --verify       # 只校验已落地文件的 md5
#
# 设计要点:
#   1. 压缩包内按【系统 tree】组织：etc/ home/ usr/ ... 即目标绝对路径去掉首个 /。
#      只遍历白名单系统目录，manifest.json / README.txt / pc-tools/ / 本脚本不会被覆盖。
#   2. 默认 DRY-RUN；--apply 才写。★ 本脚本【不重启系统、不动 ntmega、不切 USB gadget】★
#      服务激活（daemon-reload / enable / start / nmcli reload）是独立的后续步骤，
#      需显式调用 --activate，且本次 MCU 压测期间一律不执行。
#   3. 覆盖前把旧文件连同权限备份到 /home/cat/pub/backup_sys_<时间戳>/，
#      生成 manifest.tsv；任何一步失败都可 --rollback 整包还原。
#   4. 原子替换：install -m <mode> src dst.new && mv -f dst.new dst。
#   5. 每个文件落位后比对 md5，不一致立即判失败并提示回退。
# =====================================================================
set -u

ROOT="${1:-.}"
MODE="${2:-dry-run}"
BACKUP_ARG="${3:-}"

SYS_DIRS="etc home usr opt var lib bin sbin"
BACKUP_BASE=/home/cat/pub/backup_sys
TS=$(date +%Y%m%d_%H%M%S)
BACKUP="$BACKUP_BASE/$TS"

log() { echo "[deploy_sys] $*"; }
die() { log "!! $*"; exit 1; }

# 权限映射（与 vnic_install.sh 一致）
file_mode() {
    case "$1" in
        *.sh)          echo 755 ;;
        *.service)     echo 644 ;;
        *.nmconnection) echo 600 ;;
        *.conf)        echo 644 ;;
        *)             echo 644 ;;
    esac
}

list_files() {
    for d in $SYS_DIRS; do
        [ -d "$ROOT/$d" ] || continue
        find "$ROOT/$d" -type f 2>/dev/null
    done | sort
}

[ -d "$ROOT" ] || die "payload root 不存在: $ROOT"
N=$(list_files | wc -l)
[ "$N" -gt 0 ] || die "payload 内没有系统文件（白名单: $SYS_DIRS）"

log "payload root : $ROOT"
log "系统文件数    : $N"
log "模式          : $MODE"
log "★ 本脚本不重启系统 / 不动 ntmega / 不切 USB gadget"

# ---------------- 回退 ----------------
if [ "$MODE" = "--rollback" ]; then
    [ -n "$BACKUP_ARG" ] && BACKUP="$BACKUP_ARG"
    [ -f "$BACKUP/manifest.tsv" ] || die "备份清单不存在: $BACKUP/manifest.tsv"
    log "从备份回退: $BACKUP"
    OK=0; NG=0
    while IFS="$(printf '\t')" read -r REL MODE_ OLD_STATE OLD_MD5 NEW_MD5; do
        [ -n "$REL" ] || continue
        DST="/$REL"
        if [ "$OLD_STATE" = "ABSENT" ]; then
            rm -f "$DST" && log "  删除新增文件 $DST"
        else
            SRC="$BACKUP/files/$REL"
            [ -f "$SRC" ] || { log "  !! 备份缺失 $SRC"; NG=$((NG+1)); continue; }
            mkdir -p "$(dirname "$DST")"
            install -m "$MODE_" "$SRC" "$DST.new" && mv -f "$DST.new" "$DST" || { NG=$((NG+1)); continue; }
            log "  还原 $DST (mode=$MODE_)"
        fi
        OK=$((OK+1))
    done < "$BACKUP/manifest.tsv"
    log "回退完成: 成功 $OK / 失败 $NG，备份目录: $BACKUP"
    [ "$NG" -eq 0 ] || exit 1
    exit 0
fi

# ---------------- 校验 ----------------
if [ "$MODE" = "--verify" ]; then
    [ -n "$BACKUP_ARG" ] && BACKUP="$BACKUP_ARG"
    [ -f "$BACKUP/manifest.tsv" ] || die "找不到 $BACKUP/manifest.tsv"
    OK=0; NG=0
    while IFS="$(printf '\t')" read -r REL MODE_ OLD_STATE OLD_MD5 NEW_MD5; do
        [ -n "$REL" ] || continue
        CUR=$(md5sum "/$REL" 2>/dev/null | awk '{print $1}')
        if [ "$CUR" = "$NEW_MD5" ]; then OK=$((OK+1)); else
            log "  MISMATCH /$REL 期望=$NEW_MD5 实际=${CUR:-缺失}"; NG=$((NG+1))
        fi
    done < "$BACKUP/manifest.tsv"
    log "校验: OK=$OK MISMATCH=$NG"
    [ "$NG" -eq 0 ] || exit 1
    exit 0
fi

# ---------------- 主流程 ----------------
if [ "$MODE" = "--apply" ]; then
    mkdir -p "$BACKUP/files" || die "无法创建备份目录 $BACKUP"
    : > "$BACKUP/manifest.tsv"
    log "备份目录: $BACKUP"
else
    log "DRY-RUN：以下文件将被覆盖（不执行任何写操作）"
fi

OK=0; NG=0
list_files | while IFS= read -r SRC; do
    REL=${SRC#"$ROOT"/}
    DST="/$REL"
    MD=$(file_mode "$REL")
    NEW_MD5=$(md5sum "$SRC" | awk '{print $1}')
    if [ -f "$DST" ]; then
        OLD_STATE=PRESENT
        OLD_MD5=$(md5sum "$DST" | awk '{print $1}')
    else
        OLD_STATE=ABSENT
        OLD_MD5=-
    fi
    printf '  %-62s -> /%-58s mode=%s  old=%s  new=%s\n' \
        "$REL" "$REL" "$MD" "$OLD_STATE" "$(printf '%s' "$NEW_MD5" | cut -c1-12)"
done

if [ "$MODE" != "--apply" ]; then
    log "DRY-RUN 结束。要真正覆盖请加 --apply；服务激活是独立步骤（--activate，本次禁用）。"
    exit 0
fi

list_files | while IFS= read -r SRC; do :; done   # 占位，保持 sh 兼容

# 逐文件备份 + 原子覆盖 + 校验
for SRC in $(list_files); do
    REL=${SRC#"$ROOT"/}
    DST="/$REL"
    MD=$(file_mode "$REL")
    NEW_MD5=$(md5sum "$SRC" | awk '{print $1}')

    if [ -f "$DST" ]; then
        OLD_STATE=PRESENT
        OLD_MD5=$(md5sum "$DST" | awk '{print $1}')
        BPATH="$BACKUP/files/$REL"
        mkdir -p "$(dirname "$BPATH")"
        cp -a "$DST" "$BPATH" || die "备份失败: $DST"
    else
        OLD_STATE=ABSENT
        OLD_MD5=-
    fi

    mkdir -p "$(dirname "$DST")" || die "无法创建目标目录 $(dirname "$DST")"
    install -m "$MD" "$SRC" "$DST.new" || die "install 失败: $DST"
    mv -f "$DST.new" "$DST" || die "原子替换失败: $DST"
    GOT=$(md5sum "$DST" | awk '{print $1}')
    if [ "$GOT" != "$NEW_MD5" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$REL" "$MD" "$OLD_STATE" "$OLD_MD5" "$NEW_MD5" >> "$BACKUP/manifest.tsv"
        die "md5 校验失败: $DST  期望=$NEW_MD5 实际=$GOT  请用 --rollback $BACKUP 回退"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$REL" "$MD" "$OLD_STATE" "$OLD_MD5" "$NEW_MD5" >> "$BACKUP/manifest.tsv"
    OK=$((OK+1))
    log "  OK /$REL (mode=$MD, md5=$(printf '%s' "$NEW_MD5" | cut -c1-12))"
done

log "覆盖完成: $OK 个文件，0 失败"
log "备份清单: $BACKUP/manifest.tsv"
log "校验命令: sh $0 $ROOT --verify $BACKUP"
log "回退命令: sh $0 $ROOT --rollback $BACKUP"
log "★ 未重启系统、未动 ntmega、未切 USB gadget。服务激活需另行执行。"
exit 0
