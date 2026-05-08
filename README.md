# LUKS2-TPM-Auto-Unlock
The script detects the running Linux distribution, checks the boot and TPM environment, identifies the encrypted root volume, validates that it is LUKS2, enrols the TPM2 into the LUKS2 header using `systemd-cryptenroll`, updates `/etc/crypttab`, and rebuilds the initramfs.
