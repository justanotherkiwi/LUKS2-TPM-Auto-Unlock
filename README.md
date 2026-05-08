# LUKS2 TPM2 Auto-Unlock Setup

A Linux helper script for configuring **BitLocker-style TPM auto-unlock** for encrypted LUKS2 root volumes.

The script detects the running Linux distribution, checks the boot and TPM environment, identifies the encrypted root volume, validates that it is LUKS2, enrols the TPM2 into the LUKS2 header using `systemd-cryptenroll`, updates `/etc/crypttab`, and rebuilds the initramfs.

It is designed for modern Linux systems using:

- LUKS2
- systemd
- TPM2
- UEFI boot
- `systemd-cryptenroll`

The normal LUKS passphrase is preserved as a fallback.

---

## What This Does

The script performs the following actions:

1. Detects the Linux distribution and package manager.
2. Installs missing dependencies where supported.
3. Confirms the system is booted in UEFI mode.
4. Confirms a TPM2 device is available.
5. Checks Secure Boot state.
6. Detects the encrypted root LUKS device.
7. Verifies the device is using LUKS2.
8. Backs up `/etc/crypttab`.
9. Backs up the LUKS header.
10. Enrols TPM2 unlock using `systemd-cryptenroll`.
11. Adds `tpm2-device=auto` to `/etc/crypttab`.
12. Ensures TPM2/initramfs support is present.
13. Rebuilds initramfs.
14. Provides rollback instructions.

---

## What This Does Not Do

This script does **not**:

- Remove your existing LUKS password.
- Wipe or reformat your disk.
- Convert LUKS1 to LUKS2.
- Enable Secure Boot.
- Replace GRUB or change your bootloader.
- Guarantee physical attack resistance if Secure Boot is disabled.

Your existing passphrase remains usable as a recovery method.

---

## Security Model

This setup is closest to BitLocker-style behaviour when used with:

```text
LUKS2 root volume + TPM2 + UEFI + Secure Boot + PCR 7
```

The default PCR binding is:

```text
PCR 7
```

PCR 7 is normally tied to Secure Boot state. This is a good balance between security and reliability because it avoids breaking unlock after normal kernel updates on many Linux distributions.

If Secure Boot is disabled, TPM auto-unlock may still work, but it should be treated as a convenience feature rather than a full BitLocker-equivalent security posture.

Recommended final state:

```text
Secure Boot enabled
TPM2 enabled
LUKS2 root encryption enabled
TPM enrolled with PCR 7
LUKS passphrase retained as fallback
```

---

## Supported Distributions

The script is designed to support modern systemd-based distributions.

Tested or intended targets include:

| Distribution Family | Package Manager | Initramfs Builder |
|---|---:|---:|
| Fedora / RHEL-like | `dnf` | `dracut` |
| openSUSE | `zypper` | `dracut` |
| Debian / Ubuntu | `apt` | `update-initramfs` |
| Arch Linux | `pacman` | `mkinitcpio` |

Fedora is the primary target.

---

## Requirements

The system must have:

- Root privileges
- LUKS2 encrypted root volume
- TPM2 device
- systemd with TPM2 support
- `systemd-cryptenroll`
- `cryptsetup`
- An initramfs builder:
  - `dracut`, or
  - `update-initramfs`, or
  - `mkinitcpio`

Recommended:

- UEFI boot
- Secure Boot enabled

---

## Quick Start

Clone or download the script:

```bash
chmod +x luks-tpm2-auto-unlock.sh
```

Run a dry run first:

```bash
sudo ./luks-tpm2-auto-unlock.sh --dry-run
```

If the detection looks correct, run the setup:

```bash
sudo ./luks-tpm2-auto-unlock.sh
```

For unattended use:

```bash
sudo ./luks-tpm2-auto-unlock.sh --yes
```

Reboot to test:

```bash
sudo reboot
```

---

## Fedora Example

For a normal Fedora Workstation or Fedora KDE installation:

```bash
sudo ./luks-tpm2-auto-unlock.sh --dry-run
sudo ./luks-tpm2-auto-unlock.sh --yes
sudo reboot
```

After reboot:

```bash
sudo systemd-cryptenroll /dev/nvme0n1p3
cat /etc/crypttab
journalctl -b | grep -Ei 'crypt|luks|tpm|systemd-cryptsetup'
```

Replace `/dev/nvme0n1p3` with your actual LUKS device if different.

---

## Usage

```text
sudo ./luks-tpm2-auto-unlock.sh [options]
```

### Options

| Option | Description |
|---|---|
| `-y`, `--yes` | Run without confirmation prompts |
| `--dry-run` | Show what would happen without making changes |
| `--no-install` | Do not install missing packages automatically |
| `--device /dev/XYZ` | Override auto-detection and use a specific LUKS device |
| `--pcrs "7"` | Set TPM PCR binding list. Default is `7` |
| `--with-pin` | Require a TPM PIN at boot |
| `--current-kernel-only` | Rebuild only the current initramfs where supported |
| `--no-header-backup` | Skip LUKS header backup. Not recommended |
| `--allow-legacy` | Allow non-UEFI boot. Not recommended |
| `--rollback DIR` | Restore `/etc/crypttab` from backup and remove TPM enrolment |
| `-h`, `--help` | Show help |

---

## Recommended Command

For most systems:

```bash
sudo ./luks-tpm2-auto-unlock.sh --yes --pcrs "7"
```

For a more cautious first run:

```bash
sudo ./luks-tpm2-auto-unlock.sh --dry-run
```

---

## Manual Device Override

If the script cannot automatically detect your encrypted root device, specify it manually:

```bash
sudo ./luks-tpm2-auto-unlock.sh --device /dev/nvme0n1p3
```

You can identify LUKS devices with:

```bash
lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS,UUID
blkid -t TYPE=crypto_LUKS
```

---

## TPM PIN Mode

By default, the script configures automatic TPM unlock.

To require a PIN at boot:

```bash
sudo ./luks-tpm2-auto-unlock.sh --with-pin
```

This changes the boot experience from automatic unlock to TPM-backed unlock with a user PIN.

---

## PCR Selection

Default:

```bash
--pcrs "7"
```

PCR 7 is recommended for most users because it binds unlock to Secure Boot state while remaining reliable across normal kernel updates.

Examples:

```bash
sudo ./luks-tpm2-auto-unlock.sh --pcrs "7"
sudo ./luks-tpm2-auto-unlock.sh --pcrs "0+2+4+7"
```

Be careful with wider PCR bindings. Some PCR combinations may require re-enrolment after firmware, bootloader, kernel, initramfs, Secure Boot, or hardware changes.

---

## Rollback

Every run creates a backup directory similar to:

```text
/root/luks-tpm2-auto-unlock-backup-YYYYMMDD-HHMMSS
```

To roll back:

```bash
sudo ./luks-tpm2-auto-unlock.sh --rollback /root/luks-tpm2-auto-unlock-backup-YYYYMMDD-HHMMSS
```

Rollback will:

1. Restore the previous `/etc/crypttab`.
2. Remove the TPM2 enrolment from the LUKS2 volume.
3. Rebuild initramfs.

You can also manually remove TPM enrolment:

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/nvme0n1p3
sudo dracut -f
sudo reboot
```

Replace `/dev/nvme0n1p3` with your actual LUKS device.

---

## LUKS Header Backup

The script backs up the LUKS header before making changes.

Example backup path:

```text
/root/luks-tpm2-auto-unlock-backup-YYYYMMDD-HHMMSS/luks-header-UUID-YYYYMMDD-HHMMSS.img
```

Keep this file private and secure.

The LUKS header backup does not contain your passphrase in plain text, but it is sensitive metadata. Store it carefully.

---

## Verifying After Reboot

After rebooting, check the TPM enrolment:

```bash
sudo systemd-cryptenroll /dev/nvme0n1p3
```

Check `/etc/crypttab`:

```bash
cat /etc/crypttab
```

Expected options include:

```text
x-initrd.attach,tpm2-device=auto
```

Check boot logs:

```bash
journalctl -b | grep -Ei 'crypt|luks|tpm|systemd-cryptsetup'
```

---

## Example `/etc/crypttab`

Example:

```text
luks-92a85d52-a6a7-4200-b3af-1a2f1b74f7bb UUID=92a85d52-a6a7-4200-b3af-1a2f1b74f7bb none x-initrd.attach,tpm2-device=auto
```

Some distributions may also include other options such as:

```text
discard
```

Example:

```text
luks-92a85d52-a6a7-4200-b3af-1a2f1b74f7bb UUID=92a85d52-a6a7-4200-b3af-1a2f1b74f7bb none discard,x-initrd.attach,tpm2-device=auto
```

---

## Troubleshooting

### System Still Asks for LUKS Password

Check TPM enrolment:

```bash
sudo systemd-cryptenroll /dev/nvme0n1p3
```

Check crypttab:

```bash
cat /etc/crypttab
```

Check initramfs contents:

```bash
lsinitrd /boot/initramfs-$(uname -r).img | grep -Ei 'crypttab|tpm|tss|systemd-cryptsetup'
```

Rebuild initramfs:

```bash
sudo dracut -f
```

Then reboot:

```bash
sudo reboot
```

---

### TPM Device Not Found

Check firmware settings for:

- TPM
- fTPM
- PTT
- Security Device Support

Then check Linux:

```bash
ls -la /dev/tpm*
systemd-cryptenroll --tpm2-device=list
```

---

### Secure Boot Disabled

Check:

```bash
mokutil --sb-state
```

If Secure Boot is disabled, TPM unlock can still work, but it is weaker.

Recommended process:

1. Enable Secure Boot in firmware.
2. Boot Linux successfully.
3. Re-run the TPM enrolment script.
4. Reboot and verify auto-unlock.

---

### Kernel Update Broke Auto-Unlock

This is more likely if you use PCRs beyond PCR 7.

Recommended default:

```bash
--pcrs "7"
```

To re-enrol:

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="7" /dev/nvme0n1p3
sudo dracut -f
sudo reboot
```

---

## Safety Notes

Before running this on important systems:

1. Confirm your normal LUKS password works.
2. Keep a recovery boot USB available.
3. Back up important data.
4. Do not delete your passphrase key slot.
5. Keep the LUKS header backup somewhere secure.
6. Test on one machine before deploying fleet-wide.

---

## Known Limitations

- Only LUKS2 is supported.
- Non-systemd boot stacks are not supported.
- Secure Boot must be enabled separately in firmware.
- Some distributions require additional initramfs configuration.
- Arch Linux `mkinitcpio` setups are intentionally handled conservatively.
- Wider PCR selections may require re-enrolment after updates.


---

## Disclaimer

This script modifies disk encryption configuration.

Run at your own risk.

Always ensure you have:

- A known working LUKS passphrase
- A recent backup
- A recovery method
- Physical or remote console access before rebooting

Do not run this blindly on production systems without testing.
