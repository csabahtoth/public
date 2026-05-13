#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Arch Linux + Niri + Noctalia  —  Automated Installer                  ║
# ║  Run from the Arch Linux live ISO as root                               ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
success() { echo -e "${GREEN}${BOLD}    ✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}${BOLD}    ! $*${NC}"; }
die()     { echo -e "\n${RED}${BOLD}ERROR: $*${NC}\n"; exit 1; }
ask()     { echo -e "${BLUE}${BOLD}$*${NC}"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]         || die "Run as root (boot the Arch ISO and you already are)"
cat /sys/firmware/efi/fw_platform_size &>/dev/null \
                           || die "Not booted in UEFI mode — GNOME Boxes uses UEFI, check VM settings"
ping -c1 -W5 archlinux.org &>/dev/null \
                           || die "No internet connection"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║       Arch Linux  +  Niri  +  Noctalia Shell         ║"
echo "  ║               Automated Installer                     ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Gather input ──────────────────────────────────────────────────────────────
info "Available disks"
lsblk -d -o NAME,SIZE,MODEL | grep -v loop
echo

ask "Target disk — just the name, e.g. vda, sda, nvme0n1:"
read -r DISK_NAME
DISK="/dev/${DISK_NAME}"
[[ -b "$DISK" ]] || die "Disk $DISK not found"

ask "Hostname:"
read -r HOSTNAME
[[ -n "$HOSTNAME" ]] || die "Hostname cannot be empty"

ask "Username:"
read -r USERNAME
[[ -n "$USERNAME" ]] || die "Username cannot be empty"

ask "User password:"
read -rs USER_PASS; echo
ask "Confirm password:"
read -rs USER_PASS2; echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || die "Passwords do not match"

ask "Root password (leave blank to lock the root account):"
read -rs ROOT_PASS; echo

ask "Timezone, e.g. Europe/London, America/New_York [UTC]:"
read -r TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"
[[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Unknown timezone: ${TIMEZONE}"

ask "Locale [en_US.UTF-8]:"
read -r LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

ask "Keyboard layout [us]:"
read -r KEYMAP
KEYMAP="${KEYMAP:-us}"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}─── Summary ───────────────────────────────────────────────${NC}"
echo -e "  Disk      : ${RED}${BOLD}${DISK} (ALL DATA WILL BE ERASED)${NC}"
echo -e "  Hostname  : ${HOSTNAME}"
echo -e "  User      : ${USERNAME}"
echo -e "  Timezone  : ${TIMEZONE}"
echo -e "  Locale    : ${LOCALE}"
echo -e "  Keymap    : ${KEYMAP}"
echo -e "${BOLD}───────────────────────────────────────────────────────────${NC}"
echo
warn "Type 'yes' to confirm and begin installation:"
read -r CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted"

# ── Partition naming (nvme/mmcblk use a 'p' prefix for partition numbers) ─────
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART="${DISK}p"
else
    PART="${DISK}"
fi
EFI_PART="${PART}1"
SWAP_PART="${PART}2"
ROOT_PART="${PART}3"

# ── Partition ─────────────────────────────────────────────────────────────────
info "Partitioning ${DISK}"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:+4G   -t 2:8200 -c 2:"swap" "$DISK"
sgdisk -n 3:0:0     -t 3:8304 -c 3:"root" "$DISK"
partprobe "$DISK"
sleep 2
success "Partitioned"

# ── Format ────────────────────────────────────────────────────────────────────
info "Formatting"
mkfs.fat -F32 -n EFI  "$EFI_PART"
mkswap   -L   swap    "$SWAP_PART"
mkfs.ext4 -L  root -F "$ROOT_PART"
success "Formatted"

# ── Mount ─────────────────────────────────────────────────────────────────────
info "Mounting"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART"  /mnt/boot
swapon "$SWAP_PART"
success "Mounted"

# ── pacstrap ──────────────────────────────────────────────────────────────────
info "Installing base system — this will take a few minutes"
pacstrap -K /mnt \
    base linux linux-firmware \
    base-devel git \
    sudo \
    zsh bash \
    nano vim \
    networkmanager \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
    polkit \
    niri \
    alacritty \
    fuzzel \
    mako \
    xwayland-satellite \
    swaybg swayidle swaylock \
    xdg-desktop-portal-gtk xdg-utils \
    brightnessctl \
    imagemagick \
    python \
    cliphist \
    wlsunset \
    power-profiles-daemon \
    spice-vdagent \
    mesa \
    vulkan-virtio \
    noto-fonts noto-fonts-emoji \
    ttf-nerd-fonts-symbols \
    upower bluez \
    man-db man-pages
success "Base system installed"

# ── fstab ─────────────────────────────────────────────────────────────────────
info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
success "fstab written"

# ── Write chroot script ───────────────────────────────────────────────────────
info "Writing chroot configuration script"

# Note: outer heredoc is UNQUOTED so live-env variables ($USERNAME, etc.) expand
# here. Variables computed inside the chroot (\$PARTUUID etc.) are escaped.
cat > /mnt/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "\n\${CYAN}\${BOLD}==> \$*\${NC}"; }
success() { echo -e "\${GREEN}\${BOLD}    ✓ \$*\${NC}"; }

# ── Time / locale ──────────────────────────────────────────────────────────
info "Setting timezone and locale"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE} /${LOCALE} /" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
success "Locale done"

# ── Hostname ───────────────────────────────────────────────────────────────
info "Configuring hostname"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1   localhost
::1         localhost
HOSTS_EOF
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts
success "Hostname done"

# ── Root password ──────────────────────────────────────────────────────────
info "Setting root password"
if [[ -n "${ROOT_PASS}" ]]; then
    echo "root:${ROOT_PASS}" | chpasswd
else
    passwd -l root
    echo "    (root account locked — use sudo)"
fi

# ── Bootloader (systemd-boot) ──────────────────────────────────────────────
info "Installing systemd-boot"
bootctl install || warn "bootctl could not write UEFI vars (normal in chroot); files are installed"

mkdir -p /boot/loader/entries

cat > /boot/loader/loader.conf << 'LOADER_EOF'
default arch.conf
timeout 3
console-mode auto
editor no
LOADER_EOF

ROOT_PARTUUID=\$(blkid -s PARTUUID -o value "${ROOT_PART}")

cat > /boot/loader/entries/arch.conf << ENTRY_EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=\${ROOT_PARTUUID} rw quiet
ENTRY_EOF

success "Bootloader done"

# ── initramfs ─────────────────────────────────────────────────────────────
info "Generating initramfs"
mkinitcpio -P
success "initramfs done"

# ── Services ───────────────────────────────────────────────────────────────
info "Enabling services"
systemctl enable NetworkManager
systemctl enable power-profiles-daemon
systemctl enable spice-vdagentd
success "Services enabled"

# ── User ───────────────────────────────────────────────────────────────────
info "Creating user ${USERNAME}"
useradd -m -G wheel,video,input,audio -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
success "User created"

# ── paru (AUR helper) ──────────────────────────────────────────────────────
info "Installing paru (AUR helper)"
su - "${USERNAME}" << 'PARU_EOF'
git clone https://aur.archlinux.org/paru.git /tmp/paru-build
cd /tmp/paru-build
makepkg -si --noconfirm
cd /
rm -rf /tmp/paru-build
PARU_EOF
success "paru installed"

# ── Noctalia shell (AUR) ───────────────────────────────────────────────────
info "Installing Noctalia shell from AUR (may take a while)"
su - "${USERNAME}" -c 'paru -S --noconfirm noctalia-shell noctalia-qs'
success "Noctalia installed"

# ── Niri config ────────────────────────────────────────────────────────────
info "Writing niri config"
mkdir -p "/home/${USERNAME}/.config/niri"

cat > "/home/${USERNAME}/.config/niri/config.kdl" << 'NIRI_EOF'
// ── Input ────────────────────────────────────────────────────────────────
input {
    keyboard {
        xkb {
            layout "KEYMAP_PLACEHOLDER"
        }
    }
    touchpad {
        tap
        natural-scroll
    }
}

// ── Output ───────────────────────────────────────────────────────────────
// GNOME Boxes / QEMU virtual display. Adjust scale if text is too small.
output "Virtual-1" {
    scale 1.0
}

// ── Layout ───────────────────────────────────────────────────────────────
layout {
    gaps 8

    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }

    default-column-width { proportion 0.5; }

    // Required by the Noctalia stationary wallpaper option
    background-color "transparent"
}

// ── Animations ───────────────────────────────────────────────────────────
animations {
    slowdown 1.0
}

// ── Window rules (Noctalia requires rounded corners) ─────────────────────
window-rule {
    geometry-corner-radius 20
    clip-to-geometry true
}

// ── Blur (niri 26.04+) ───────────────────────────────────────────────────
window-rule {
    background-effect {
        blur true
        xray false
    }
}
layer-rule {
    match namespace="^noctalia-(background|launcher-overlay|dock)-.*$"
    background-effect { xray false }
}
blur {
    passes 2
    offset 3.0
    noise 0.03
    saturation 1.0
}

// ── Noctalia — wallpaper (blurred overview mode) ──────────────────────────
layer-rule {
    match namespace="^noctalia-overview*"
    place-within-backdrop true
}

// ── Noctalia — required for app activation to work correctly ─────────────
debug {
    honor-xdg-activation-with-invalid-serial
}

// ── Autostart ────────────────────────────────────────────────────────────
spawn-at-startup "noctalia-shell"
spawn-at-startup "mako"
spawn-at-startup "xwayland-satellite"

// ── Key bindings ─────────────────────────────────────────────────────────
binds {
    // Apps
    Mod+T { spawn "alacritty"; }
    Mod+D { spawn "fuzzel"; }

    // Window management
    Mod+Q { close-window; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+R { switch-preset-column-width; }

    // Focus
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-or-workspace-up; }
    Mod+Down  { focus-window-or-workspace-down; }
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+K { focus-window-or-workspace-up; }
    Mod+J { focus-window-or-workspace-down; }

    // Move windows
    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Shift+H { move-column-left; }
    Mod+Shift+L { move-column-right; }

    // Workspaces
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }

    // Session
    Mod+Shift+E { quit; }
    Mod+Shift+P { power-off-monitors; }

    // Audio (pipewire via wpctl)
    XF86AudioRaiseVolume  { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+"; }
    XF86AudioLowerVolume  { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"; }
    XF86AudioMute         { spawn "wpctl" "set-mute"   "@DEFAULT_AUDIO_SINK@" "toggle"; }

    // Brightness
    XF86MonBrightnessUp   { spawn "brightnessctl" "set" "10%+"; }
    XF86MonBrightnessDown { spawn "brightnessctl" "set" "10%-"; }
}
NIRI_EOF

# Substitute keymap placeholder with actual value
sed -i "s/KEYMAP_PLACEHOLDER/${KEYMAP}/" "/home/${USERNAME}/.config/niri/config.kdl"

success "niri config written"

# ── Auto-start niri on TTY1 login ──────────────────────────────────────────
cat >> "/home/${USERNAME}/.bash_profile" << 'PROFILE_EOF'

# Launch niri-session automatically on TTY1
if [[ -z "\${WAYLAND_DISPLAY}" ]] && [[ "\${XDG_VTNR}" == "1" ]]; then
    exec niri-session
fi
PROFILE_EOF

# ── Auto-login on TTY1 ────────────────────────────────────────────────────
info "Configuring TTY1 auto-login for ${USERNAME}"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
AUTOLOGIN_EOF
success "Auto-login configured"

# ── Fix ownership ─────────────────────────────────────────────────────────
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

echo
echo -e "\${GREEN}\${BOLD}════════════════════════════════════════════════${NC}"
echo -e "\${GREEN}\${BOLD}  Chroot configuration complete!                ${NC}"
echo -e "\${GREEN}\${BOLD}════════════════════════════════════════════════${NC}"
CHROOT_EOF

chmod +x /mnt/root/chroot-install.sh

# ── Run chroot ────────────────────────────────────────────────────────────────
info "Running chroot configuration"
arch-chroot /mnt /root/chroot-install.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────
info "Cleaning up"
rm /mnt/root/chroot-install.sh
umount -R /mnt
swapoff "$SWAP_PART"

echo
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!                              ${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo
echo -e "  Remove the ISO in GNOME Boxes, then:"
echo -e "  ${BOLD}reboot${NC}"
echo
echo -e "  On first boot, niri will start automatically."
echo -e "  Open Noctalia settings to pick a wallpaper and theme."
echo
echo -e "  Useful first steps inside the VM:"
echo -e "    ${BOLD}Super+T${NC}  — terminal (alacritty)"
echo -e "    ${BOLD}Super+D${NC}  — app launcher (fuzzel)"
echo -e "    ${BOLD}Super+Q${NC}  — close window"
echo
