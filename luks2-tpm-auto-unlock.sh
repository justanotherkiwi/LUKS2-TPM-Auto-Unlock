#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || echo unknown-host)"
LOG="/var/log/luks-tpm2-auto-unlock-${HOST}-${TS}.log"
BACKUP_DIR="/root/luks-tpm2-auto-unlock-backup-${TS}"

YES=0
DRY_RUN=0
INSTALL_MISSING=1
ALLOW_LEGACY=0
LUKS_DEV_OVERRIDE=""
PCRS="7"
WITH_PIN=0
REBUILD_ALL=1
NO_HEADER_BACKUP=0
ROLLBACK=0
ROLLBACK_DIR=""

OS_ID="unknown"
OS_ID_LIKE=""
OS_PRETTY="unknown"
PKG_MANAGER=""
INITRAMFS_BUILDER=""
TPM_DEV=""
ROOT_SRC=""
ROOT_MAPPER=""
LUKS_DEV=""
LUKS_UUID=""
CRYPTTAB_NAME=""
CRYPTTAB_WAS_CHANGED=0
ENROLLED_TPM=0

usage() {
    cat <<EOF
Usage:
  sudo ${SCRIPT_NAME} [options]

Purpose:
  Detect the Linux distro, encrypted root LUKS2 volume, TPM2 support, initramfs
  builder, and configure TPM2 auto-unlock using systemd-cryptenroll.

Default behaviour:
  - Installs missing required packages where supported
  - Detects the encrypted root LUKS2 device automatically
  - Backs up /etc/crypttab and the LUKS header
  - Enrols TPM2 into the LUKS2 volume
  - Adds tpm2-device=auto to /etc/crypttab
  - Rebuilds initramfs
  - Keeps your normal LUKS passphrase as fallback

Options:
  -y, --yes                  Do not prompt for confirmation
      --dry-run              Show what would happen without changing anything
      --no-install           Do not install missing packages automatically
      --device /dev/XYZ      Override auto-detection and use this LUKS device
      --pcrs "7"             PCR list for TPM binding. Default: 7
      --with-pin             Require a TPM PIN at boot instead of full auto-unlock
      --current-kernel-only  Rebuild only the current initramfs where supported
      --no-header-backup     Skip LUKS header backup. Not recommended
      --allow-legacy         Allow non-UEFI boot. Not recommended
      --rollback DIR         Restore /etc/crypttab from backup dir and wipe TPM slot
  -h, --help                 Show this help

Examples:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --yes
  sudo ./${SCRIPT_NAME} --yes --pcrs "7"
  sudo ./${SCRIPT_NAME} --device /dev/nvme0n1p3 --yes
  sudo ./${SCRIPT_NAME} --rollback /root/luks-tpm2-auto-unlock-backup-YYYYMMDD-HHMMSS

Notes:
  PCR 7 is the safest default for reliability. It binds to Secure Boot state
  without constantly breaking after normal kernel updates on many distros.

  If Secure Boot is disabled, TPM unlock will still provide convenience, but it
  is not as strong as BitLocker-style TPM + Secure Boot binding. If you enable
  Secure Boot later, re-run this script so PCR 7 is enrolled against the new state.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-install) INSTALL_MISSING=0; shift ;;
        --device) LUKS_DEV_OVERRIDE="${2:-}"; shift 2 ;;
        --pcrs) PCRS="${2:-}"; shift 2 ;;
        --with-pin) WITH_PIN=1; shift ;;
        --current-kernel-only) REBUILD_ALL=0; shift ;;
        --no-header-backup) NO_HEADER_BACKUP=1; shift ;;
        --allow-legacy) ALLOW_LEGACY=1; shift ;;
        --rollback) ROLLBACK=1; ROLLBACK_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG" || true

log() {
    echo "$*" | tee -a "$LOG"
}

warn() {
    log "WARNING: $*"
}

die() {
    log "ERROR: $*"
    log "Log file: $LOG"
    exit 1
}

run() {
    log "+ $*"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    "$@" 2>&1 | tee -a "$LOG"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

confirm() {
    local prompt="$1"
    if [[ "$YES" -eq 1 ]]; then
        log "$prompt: YES (--yes supplied)"
        return 0
    fi

    local answer
    read -r -p "$prompt Type YES to continue: " answer
    [[ "$answer" == "YES" ]]
}

mask_secretish() {
    sed -E \
        -e 's#([[:space:]]+/[^[:space:]]*(key|secret|password|passphrase)[^[:space:]]*)# [REDACTED-POSSIBLE-SECRET-PATH]#Ig' \
        -e 's#(password=)[^,[:space:]]+#\1[REDACTED]#Ig' \
        -e 's#(passphrase=)[^,[:space:]]+#\1[REDACTED]#Ig' \
        -e 's#(keyfile=)[^,[:space:]]+#\1[REDACTED]#Ig' \
        -e 's#(rd.luks.key=)[^ ]+#\1[REDACTED]#Ig'
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
    fi

    if have dnf; then
        PKG_MANAGER="dnf"
    elif have zypper; then
        PKG_MANAGER="zypper"
    elif have apt-get; then
        PKG_MANAGER="apt"
    elif have pacman; then
        PKG_MANAGER="pacman"
    else
        PKG_MANAGER="unknown"
    fi
}

install_packages_for_distro() {
    local missing=("$@")
    [[ "${#missing[@]}" -gt 0 ]] || return 0

    if [[ "$INSTALL_MISSING" -ne 1 ]]; then
        die "Missing required commands: ${missing[*]}. Re-run without --no-install or install dependencies manually."
    fi

    local packages=()

    case "$PKG_MANAGER" in
        dnf)
            packages=(cryptsetup systemd tpm2-tools dracut mokutil python3 util-linux)
            run dnf install -y "${packages[@]}"
            ;;
        zypper)
            packages=(cryptsetup systemd tpm2.0-tools dracut mokutil python3 util-linux)
            run zypper --non-interactive install "${packages[@]}"
            ;;
        apt)
            packages=(cryptsetup systemd tpm2-tools initramfs-tools mokutil python3 util-linux)
            run apt-get update
            run apt-get install -y "${packages[@]}"
            ;;
        pacman)
            packages=(cryptsetup systemd tpm2-tools mkinitcpio mokutil python util-linux)
            run pacman -Sy --needed --noconfirm "${packages[@]}"
            ;;
        *)
            die "Unsupported package manager. Missing commands: ${missing[*]}"
            ;;
    esac
}

ensure_commands() {
    local required=(cryptsetup systemd-cryptenroll lsblk blkid findmnt awk sed grep python3)
    local optional=(mokutil tpm2_getcap tpm2_pcrread lsinitrd lsinitramfs)
    local missing=()

    for c in "${required[@]}"; do
        have "$c" || missing+=("$c")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        install_packages_for_distro "${missing[@]}"
    fi

    missing=()
    for c in "${required[@]}"; do
        have "$c" || missing+=("$c")
    done

    [[ "${#missing[@]}" -eq 0 ]] || die "Required commands still missing after package install attempt: ${missing[*]}"

    for c in "${optional[@]}"; do
        have "$c" || warn "Optional command not found: $c"
    done
}

detect_initramfs_builder() {
    if have dracut; then
        INITRAMFS_BUILDER="dracut"
    elif have update-initramfs; then
        INITRAMFS_BUILDER="update-initramfs"
    elif have mkinitcpio; then
        INITRAMFS_BUILDER="mkinitcpio"
    else
        die "No supported initramfs builder found. Need dracut, update-initramfs, or mkinitcpio."
    fi
}

check_boot_and_tpm() {
    log "Checking boot mode..."

    if [[ -d /sys/firmware/efi ]]; then
        log "UEFI boot: yes"
    else
        if [[ "$ALLOW_LEGACY" -eq 1 ]]; then
            warn "UEFI boot not detected, continuing because --allow-legacy was supplied."
        else
            die "UEFI boot not detected. Use --allow-legacy to bypass, but this is not BitLocker-like."
        fi
    fi

    log "Checking TPM2 device..."

    if [[ -e /dev/tpmrm0 ]]; then
        TPM_DEV="/dev/tpmrm0"
    elif [[ -e /dev/tpm0 ]]; then
        TPM_DEV="/dev/tpm0"
    else
        die "No TPM device found at /dev/tpmrm0 or /dev/tpm0. Enable TPM/fTPM/PTT in firmware."
    fi

    log "TPM device: $TPM_DEV"

    log "Checking systemd TPM2 support..."
    systemd-cryptenroll --tpm2-device=list 2>&1 | tee -a "$LOG" || die "systemd-cryptenroll cannot list TPM2 devices."

    log "Checking Secure Boot state..."

    if have mokutil; then
        local sb
        sb="$(mokutil --sb-state 2>/dev/null || true)"
        echo "$sb" | tee -a "$LOG"

        if echo "$sb" | grep -qi "disabled"; then
            warn "Secure Boot is disabled. TPM auto-unlock will work for convenience, but it is not as strong as BitLocker-style TPM + Secure Boot."
            warn "If you enable Secure Boot later, re-run this script to re-enrol TPM against the new PCR 7 state."
        fi

        if echo "$sb" | grep -qi "Setup Mode"; then
            warn "Platform is in Secure Boot Setup Mode. Enrol platform keys / enable Secure Boot for stronger measured boot protection."
        fi
    else
        warn "mokutil missing; cannot determine Secure Boot state."
    fi
}

strip_findmnt_source() {
    local src="$1"
    src="${src%%[*}"
    echo "$src"
}

find_luks_device_for_root() {
    if [[ -n "$LUKS_DEV_OVERRIDE" ]]; then
        LUKS_DEV="$LUKS_DEV_OVERRIDE"
        log "Using user-supplied LUKS device: $LUKS_DEV"
        return 0
    fi

    ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -n "$ROOT_SRC" ]] || die "Could not determine root filesystem source."

    ROOT_SRC="$(strip_findmnt_source "$ROOT_SRC")"
    ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"

    log "Root source: $ROOT_SRC"

    if cryptsetup status "$ROOT_SRC" >/tmp/luks-tpm2-root-status.$$ 2>/dev/null; then
        ROOT_MAPPER="$(basename "$ROOT_SRC")"
        LUKS_DEV="$(awk -F: '/^[[:space:]]*device:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /tmp/luks-tpm2-root-status.$$)"
        rm -f /tmp/luks-tpm2-root-status.$$

        [[ -n "$LUKS_DEV" ]] || die "Root is a crypt mapping but underlying device could not be determined."

        log "Detected root crypt mapper: $ROOT_MAPPER"
        log "Detected root LUKS device: $LUKS_DEV"
        return 0
    fi

    rm -f /tmp/luks-tpm2-root-status.$$

    log "Root source was not directly a crypt mapping. Searching parent block devices..."

    local candidate=""
    candidate="$(lsblk -spno PATH,FSTYPE "$ROOT_SRC" 2>/dev/null | awk '$2 == "crypto_LUKS" {print $1; exit}')"

    if [[ -n "$candidate" ]]; then
        LUKS_DEV="$candidate"
        ROOT_MAPPER="luks-$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || true)"
        log "Detected parent LUKS device: $LUKS_DEV"
        return 0
    fi

    local luks_count
    luks_count="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | wc -l | awk '{print $1}')"

    if [[ "$luks_count" == "1" ]]; then
        LUKS_DEV="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null)"
        ROOT_MAPPER="luks-$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || true)"
        warn "Could not prove root ancestry, but exactly one LUKS device exists. Using: $LUKS_DEV"
        return 0
    fi

    die "Could not auto-detect encrypted root LUKS device. Re-run with --device /dev/XYZ."
}

validate_luks_device() {
    [[ -b "$LUKS_DEV" ]] || die "LUKS device is not a block device: $LUKS_DEV"

    cryptsetup isLuks "$LUKS_DEV" || die "Device is not recognised as LUKS: $LUKS_DEV"

    local ver
    ver="$(cryptsetup luksDump "$LUKS_DEV" | awk '/Version:/ {print $2; exit}')"

    [[ "$ver" == "2" ]] || die "Only LUKS2 is supported. $LUKS_DEV is LUKS version: ${ver:-unknown}"

    LUKS_UUID="$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || true)"
    [[ -n "$LUKS_UUID" ]] || die "Could not determine LUKS UUID for $LUKS_DEV"

    if [[ -z "$ROOT_MAPPER" || "$ROOT_MAPPER" == "luks-" ]]; then
        ROOT_MAPPER="luks-${LUKS_UUID}"
    fi

    CRYPTTAB_NAME="$ROOT_MAPPER"

    log "LUKS validation: OK"
    log "LUKS device:    $LUKS_DEV"
    log "LUKS UUID:      $LUKS_UUID"
    log "crypttab name:  $CRYPTTAB_NAME"

    log "Existing enrolment state:"
    systemd-cryptenroll "$LUKS_DEV" 2>&1 | tee -a "$LOG" || true
}

prepare_backups() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    log "Backup directory: $BACKUP_DIR"

    if [[ -f /etc/crypttab ]]; then
        run cp -a /etc/crypttab "$BACKUP_DIR/crypttab.backup"
    else
        log "No /etc/crypttab exists; creating empty backup marker."
        : > "$BACKUP_DIR/crypttab.backup.empty"
    fi

    case "$INITRAMFS_BUILDER" in
        dracut)
            [[ -d /etc/dracut.conf.d ]] && run cp -a /etc/dracut.conf.d "$BACKUP_DIR/dracut.conf.d.backup" || true
            [[ -f /etc/dracut.conf ]] && run cp -a /etc/dracut.conf "$BACKUP_DIR/dracut.conf.backup" || true
            ;;
        update-initramfs)
            [[ -d /etc/initramfs-tools ]] && run cp -a /etc/initramfs-tools "$BACKUP_DIR/initramfs-tools.backup" || true
            ;;
        mkinitcpio)
            [[ -f /etc/mkinitcpio.conf ]] && run cp -a /etc/mkinitcpio.conf "$BACKUP_DIR/mkinitcpio.conf.backup" || true
            ;;
    esac

    if [[ "$NO_HEADER_BACKUP" -ne 1 ]]; then
        local header="$BACKUP_DIR/luks-header-${LUKS_UUID}-${TS}.img"

        log "Backing up LUKS header to: $header"
        run cryptsetup luksHeaderBackup "$LUKS_DEV" --header-backup-file "$header"

        [[ "$DRY_RUN" -eq 1 ]] || chmod 600 "$header"

        log "IMPORTANT: Keep the LUKS header backup private and copy it somewhere safe."
    else
        warn "Skipping LUKS header backup because --no-header-backup was supplied."
    fi
}

configure_initramfs_support() {
    log "Configuring initramfs support for builder: $INITRAMFS_BUILDER"

    case "$INITRAMFS_BUILDER" in
        dracut)
            run mkdir -p /etc/dracut.conf.d

            if [[ "$DRY_RUN" -ne 1 ]]; then
                cat > /etc/dracut.conf.d/90-luks-tpm2-auto-unlock.conf <<'EOF'
# Added by luks-tpm2-auto-unlock
# Ensures TPM2/systemd crypt unlock support and /etc/crypttab are present in initramfs.
add_dracutmodules+=" tpm2-tss crypt systemd "
install_items+=" /etc/crypttab "
EOF
            else
                log "Would write /etc/dracut.conf.d/90-luks-tpm2-auto-unlock.conf"
            fi
            ;;
        update-initramfs)
            run mkdir -p /etc/initramfs-tools/conf.d

            if [[ "$DRY_RUN" -ne 1 ]]; then
                cat > /etc/initramfs-tools/conf.d/luks-tpm2-auto-unlock <<'EOF'
# Marker file added by luks-tpm2-auto-unlock.
# TPM2 unlock is configured via /etc/crypttab using tpm2-device=auto.
EOF
            else
                log "Would write /etc/initramfs-tools/conf.d/luks-tpm2-auto-unlock"
            fi
            ;;
        mkinitcpio)
            if [[ ! -f /etc/mkinitcpio.conf ]]; then
                die "mkinitcpio detected but /etc/mkinitcpio.conf not found."
            fi

            if ! grep -Eq '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf || ! grep -Eq '^HOOKS=.*\bsd-encrypt\b' /etc/mkinitcpio.conf; then
                die "mkinitcpio systems need systemd and sd-encrypt hooks in /etc/mkinitcpio.conf. Add them, then re-run. I will not rewrite Arch boot hooks automatically."
            fi
            ;;
    esac
}

update_crypttab() {
    log "Updating /etc/crypttab..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Would add/update crypttab entry for UUID=$LUKS_UUID with tpm2-device=auto and x-initrd.attach"
        return 0
    fi

    python3 - <<PY
from pathlib import Path

path = Path('/etc/crypttab')
name = '${CRYPTTAB_NAME}'
uuid = '${LUKS_UUID}'
device_uuid = f'UUID={uuid}'

if path.exists():
    lines = path.read_text().splitlines()
else:
    lines = []

new_lines = []
found = False
changed = False

for line in lines:
    original = line
    stripped = line.strip()

    if not stripped or stripped.startswith('#'):
        new_lines.append(line)
        continue

    parts = line.split()

    if len(parts) < 2:
        new_lines.append(line)
        continue

    entry_name = parts[0]
    entry_dev = parts[1]

    if entry_name == name or entry_dev == device_uuid or entry_dev.endswith('/' + uuid):
        found = True

        while len(parts) < 3:
            parts.append('none')

        while len(parts) < 4:
            parts.append('')

        if parts[2] in ('', '-'):
            parts[2] = 'none'

        opts = [x for x in parts[3].split(',') if x]

        for opt in ('x-initrd.attach', 'tpm2-device=auto'):
            if opt not in opts:
                opts.append(opt)
                changed = True

        parts[3] = ','.join(opts)
        line = ' '.join(parts)

        if line != original:
            changed = True

    new_lines.append(line)

if not found:
    new_lines.append(f'{name} {device_uuid} none x-initrd.attach,tpm2-device=auto')
    changed = True

if changed:
    path.write_text('\\n'.join(new_lines) + '\\n')
PY

    CRYPTTAB_WAS_CHANGED=1

    log "Resulting crypttab entry:"
    grep -E "^${CRYPTTAB_NAME}[[:space:]]|UUID=${LUKS_UUID}" /etc/crypttab | mask_secretish | tee -a "$LOG" || true
}

enroll_tpm() {
    log "Enrolling TPM2 token into LUKS2 device..."
    log "You may be prompted for your existing LUKS passphrase. Your passphrase slot will remain as fallback."

    local args=(systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$PCRS")

    if [[ "$WITH_PIN" -eq 1 ]]; then
        args+=(--tpm2-with-pin=yes)
    fi

    args+=("$LUKS_DEV")

    run "${args[@]}"
    ENROLLED_TPM=1

    log "Enrolment state after TPM setup:"
    systemd-cryptenroll "$LUKS_DEV" 2>&1 | tee -a "$LOG" || true
}

rebuild_initramfs() {
    log "Rebuilding initramfs using: $INITRAMFS_BUILDER"

    case "$INITRAMFS_BUILDER" in
        dracut)
            if [[ "$REBUILD_ALL" -eq 1 ]]; then
                if ! run dracut --regenerate-all --force; then
                    warn "dracut --regenerate-all failed; trying dracut -f for current kernel."
                    run dracut -f
                fi
            else
                run dracut -f
            fi
            ;;
        update-initramfs)
            if [[ "$REBUILD_ALL" -eq 1 ]]; then
                run update-initramfs -u -k all
            else
                run update-initramfs -u -k "$(uname -r)"
            fi
            ;;
        mkinitcpio)
            run mkinitcpio -P
            ;;
    esac

    run systemctl daemon-reload || true
}

validate_initramfs() {
    log "Validating resulting initramfs where possible..."

    if have lsinitrd; then
        local latest=""
        latest="$(ls -1t /boot/initramfs-*.img /boot/initrd*.img 2>/dev/null | head -1 || true)"

        if [[ -n "$latest" ]]; then
            log "Latest initramfs: $latest"
            lsinitrd "$latest" 2>/dev/null | grep -Ei 'crypttab|systemd-cryptsetup|tpm2|tss|libcryptsetup-token-systemd-tpm2' | tee -a "$LOG" || warn "Could not confirm TPM/systemd crypt files inside initramfs."
        else
            warn "No initramfs image found under /boot for lsinitrd validation."
        fi
    elif have lsinitramfs; then
        local latest=""
        latest="$(ls -1t /boot/initrd.img-* /boot/initramfs-*.img 2>/dev/null | head -1 || true)"

        if [[ -n "$latest" ]]; then
            log "Latest initramfs: $latest"
            lsinitramfs "$latest" 2>/dev/null | grep -Ei 'crypttab|systemd-cryptsetup|tpm2|tss|libcryptsetup-token-systemd-tpm2' | tee -a "$LOG" || warn "Could not confirm TPM/systemd crypt files inside initramfs."
        else
            warn "No initramfs image found under /boot for lsinitramfs validation."
        fi
    else
        warn "No lsinitrd/lsinitramfs tool available for validation."
    fi
}

rollback() {
    [[ -n "$ROLLBACK_DIR" ]] || die "--rollback requires a backup directory path."
    [[ -d "$ROLLBACK_DIR" ]] || die "Backup directory not found: $ROLLBACK_DIR"

    log "Rollback requested using: $ROLLBACK_DIR"

    detect_os
    ensure_commands
    detect_initramfs_builder
    find_luks_device_for_root
    validate_luks_device

    confirm "Rollback will wipe TPM2 enrolment from $LUKS_DEV and restore crypttab backup." || die "Rollback cancelled."

    if [[ -f "$ROLLBACK_DIR/crypttab.backup" ]]; then
        run cp -a "$ROLLBACK_DIR/crypttab.backup" /etc/crypttab
    elif [[ -f "$ROLLBACK_DIR/crypttab.backup.empty" ]]; then
        run rm -f /etc/crypttab
    else
        die "No crypttab backup found in $ROLLBACK_DIR"
    fi

    run systemd-cryptenroll --wipe-slot=tpm2 "$LUKS_DEV"
    rebuild_initramfs

    log "Rollback complete. Reboot to test."
    exit 0
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: run as root: sudo ./${SCRIPT_NAME}"
        exit 1
    fi

    log "============================================================"
    log "Linux LUKS2 TPM2 Auto-Unlock Ultimate Setup"
    log "============================================================"
    log "Started: $(date -Is)"
    log "Log:     $LOG"
    log ""

    if [[ "$ROLLBACK" -eq 1 ]]; then
        rollback
    fi

    detect_os

    log "Detected OS:       $OS_PRETTY"
    log "Detected ID:       $OS_ID"
    log "Detected ID_LIKE:  $OS_ID_LIKE"
    log "Package manager:   $PKG_MANAGER"

    ensure_commands
    detect_initramfs_builder

    log "Initramfs builder: $INITRAMFS_BUILDER"

    check_boot_and_tpm
    find_luks_device_for_root
    validate_luks_device

    log ""
    log "Planned configuration:"
    log "  Distro:              $OS_PRETTY"
    log "  Initramfs builder:   $INITRAMFS_BUILDER"
    log "  TPM device:          $TPM_DEV"
    log "  LUKS device:         $LUKS_DEV"
    log "  LUKS UUID:           $LUKS_UUID"
    log "  crypttab name:       $CRYPTTAB_NAME"
    log "  PCRs:                $PCRS"
    log "  TPM PIN required:    $([[ "$WITH_PIN" -eq 1 ]] && echo yes || echo no)"
    log "  Rebuild all kernels: $([[ "$REBUILD_ALL" -eq 1 ]] && echo yes || echo no)"
    log "  Backup directory:    $BACKUP_DIR"
    log ""

    confirm "Proceed with TPM2 auto-unlock setup?" || die "Cancelled by user."

    prepare_backups
    configure_initramfs_support
    update_crypttab
    enroll_tpm
    rebuild_initramfs
    validate_initramfs

    log ""
    log "============================================================"
    log "Completed"
    log "============================================================"
    log "Reboot to test:"
    log "  sudo reboot"
    log ""
    log "Expected result:"
    log "  The system should unlock the encrypted root volume using TPM2."
    log "  Your normal LUKS passphrase remains available as fallback."
    log ""
    log "Post-reboot checks:"
    log "  sudo systemd-cryptenroll $LUKS_DEV"
    log "  cat /etc/crypttab"
    log "  journalctl -b | grep -Ei 'crypt|luks|tpm|systemd-cryptsetup'"
    log ""
    log "Rollback:"
    log "  sudo ./${SCRIPT_NAME} --rollback '$BACKUP_DIR'"
    log ""
    log "Log file:"
    log "  $LOG"
    log "Backup directory:"
    log "  $BACKUP_DIR"
}

main "$@"
