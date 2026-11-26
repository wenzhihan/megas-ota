#!/bin/sh
# =====================================================================
# ssh_harden.sh - idempotent sshd config hardening for OTA reboot loops
# Called by runUpdate-sys.sh as root ($SUDO sh ssh_harden.sh).
# Invariant: NEVER leave sshd in a state where it cannot start.
#   - validates with `sshd -t` (syntax) and `sshd -T` (effective values)
#   - on any failure, restores the original sshd_config from backup
#   - prints SSH_HARDEN_OK / SSH_HARDEN_FAIL for the caller
# =====================================================================
set -u

CONF=/etc/ssh/sshd_config
DROP=/etc/ssh/sshd_config.d/99-megas-ota.conf
BAK=
SSHD=/usr/sbin/sshd
[ -x "$SSHD" ] || SSHD=$(command -v sshd || echo /usr/sbin/sshd)

log() { echo "[ssh_harden] $*"; }
restore() {
    if [ -n "$BAK" ] && [ -f "$BAK" ]; then
        cp -a "$BAK" "$CONF" && chmod 644 "$CONF" && log "restored $CONF from $BAK"
    fi
}
fail() { log "!! $*"; restore; echo "SSH_HARDEN_FAIL"; exit 1; }
backup_once() {
    [ -n "$BAK" ] && return 0
    BAK="$CONF.bak.megas-ota.$(date +%Y%m%d_%H%M%S)"
    cp -a "$CONF" "$BAK" || fail "cannot backup $CONF"
    log "backup: $BAK"
}
eff() { "$SSHD" -T 2>/dev/null | grep -iE '^(usedns|maxstartups|logingracetime) '; }
check_values() {
    E=$(eff)
    log "effective: $(printf '%s' "$E" | tr '\n' ';')"
    printf '%s\n' "$E" | grep -qi '^usedns no' || return 1
    printf '%s\n' "$E" | grep -qi '^maxstartups 100:30:200' || return 1
    printf '%s\n' "$E" | grep -qi '^logingracetime 30' || return 1
    return 0
}

[ -f "$CONF" ] || fail "$CONF missing"

# ---- 1. Ensure Include exists and is at the TOP (OpenSSH: first value wins) ----
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$CONF"; then
    backup_once
    { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat "$CONF"; } > "$CONF.new" ||
        fail "cannot write $CONF.new"
    mv -f "$CONF.new" "$CONF" || fail "cannot replace $CONF"
    chmod 644 "$CONF"
    log "inserted Include as first line of $CONF"
fi

# ---- 2. Drop-in (normally installed by deploy_sys.sh --apply); fallback write ----
if [ ! -f "$DROP" ]; then
    backup_once
    mkdir -p /etc/ssh/sshd_config.d || fail "cannot create sshd_config.d"
    printf '%s\n' \
        '# MEGAS OTA v9.9.22 - keep sshd reachable across OTA reboot loops.' \
        'UseDNS no' 'MaxStartups 100:30:200' 'LoginGraceTime 30' > "$DROP" ||
        fail "cannot write $DROP"
    chmod 644 "$DROP"
    log "created $DROP (fallback)"
fi

# ---- 3. Validate: syntax first, then effective values ----
"$SSHD" -t 2>&1 || fail "sshd -t syntax check failed"
if check_values; then
    log "drop-in effective, no main-config rewrite needed"
    echo "SSH_HARDEN_OK"
    exit 0
fi

# ---- 4. Fallback: rewrite main config (older distro / Include placed too late) ----
log "drop-in not effective -> rewriting explicit directives in $CONF"
backup_once
awk '
    /^[[:space:]]*(UseDNS|MaxStartups|LoginGraceTime)[[:space:]]/ { print "# " $0; next }
    { print }
' "$CONF" > "$CONF.new" || fail "awk rewrite failed"
printf '\n# MEGAS OTA v9.9.22 (fallback)\nUseDNS no\nMaxStartups 100:30:200\nLoginGraceTime 30\n' >> "$CONF.new" ||
    fail "append failed"
mv -f "$CONF.new" "$CONF" || fail "replace $CONF failed"
chmod 644 "$CONF"

"$SSHD" -t 2>&1 || fail "sshd -t failed after main-config rewrite"
if ! check_values; then
    fail "effective values still wrong after rewrite"
fi
log "main-config fallback effective"
echo "SSH_HARDEN_OK"
exit 0
