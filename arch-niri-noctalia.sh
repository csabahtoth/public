#!/usr/bin/env bash
# Post-install script: niri + Noctalia shell on Arch Linux
# Tested target: minimal Arch install, btrfs/snapper, UK keyboard, pipewire
# Future target:  Framework 13 AMD 7040 (hardware section gated behind --hardware flag)
#
# Usage (local):
#   chmod +x arch-niri-noctalia.sh
#   ./arch-niri-noctalia.sh            # VM / safe mode
#   ./arch-niri-noctalia.sh --hardware # Full install for Framework 13 AMD
#
# Usage (from GitHub) — MUST use process substitution, NOT curl | bash,
# so stdin stays attached to your terminal for sudo/password prompts:
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/arch-niri-noctalia.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/arch-niri-noctalia.sh) --hardware

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ── Sanity check ──────────────────────────────────────────────────────────────
command -v pacman &>/dev/null || err "pacman not found — this script requires Arch Linux."

# ── Root / sudo detection ─────────────────────────────────────────────────────
# On a fresh minimal Arch install sudo is not present and the user is typically
# root. We support both modes:
#   root        → SUDO="" so every $SUDO call runs directly; makepkg gets
#                 --allow-root because it refuses to build as root otherwise.
#   normal user → SUDO="sudo"; we verify sudo is installed and working before
#                 doing anything else.
if [[ $EUID -eq 0 ]]; then
    warn "Running as root."
    warn "This works, but creating a regular user for daily use is recommended:"
    warn "  useradd -m -G wheel -s /bin/bash USERNAME && passwd USERNAME"
    echo ""
    SUDO=""
    MAKEPKG_EXTRA="--allow-root"
    # When root, $USER is 'root'. We only add real users to video/input groups.
    TARGET_USER=""
else
    # Ensure sudo is installed — it is NOT included in a minimal Arch base.
    if ! command -v sudo &>/dev/null; then
        err "sudo is not installed. Log in as root and run:" \
            $'\n'"  pacman -S sudo" \
            $'\n'"  usermod -aG wheel $USER" \
            $'\n'"  EDITOR=nano visudo   # uncomment: %wheel ALL=(ALL:ALL) ALL"
    fi
    # Ensure this user can actually use sudo before any privileged command runs.
    if ! sudo -v 2>/dev/null; then
        err "$USER cannot use sudo. As root, run:" \
            $'\n'"  usermod -aG wheel $USER" \
            $'\n'"  EDITOR=nano visudo   # uncomment: %wheel ALL=(ALL:ALL) ALL"
    fi
    SUDO="sudo"
    MAKEPKG_EXTRA=""
    TARGET_USER="$USER"
fi

# ── Args ──────────────────────────────────────────────────────────────────────
HARDWARE_MODE=false
for arg in "$@"; do
    [[ "$arg" == "--hardware" ]] && HARDWARE_MODE=true
done

info "Starting niri + Noctalia post-install (hardware mode: $HARDWARE_MODE)"
echo ""

# ── 1. Full system update ─────────────────────────────────────────────────────
info "Updating system..."
$SUDO pacman -Syu --noconfirm

# ── 2. Base build tools (needed to compile AUR packages) ─────────────────────
info "Installing base-devel and git..."
$SUDO pacman -S --needed --noconfirm base-devel git curl

# ── 3. AUR helper: paru ───────────────────────────────────────────────────────
if ! command -v paru &>/dev/null; then
    info "Installing paru (AUR helper)..."
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    git clone https://aur.archlinux.org/paru-bin.git "$tmpdir/paru"
    # makepkg refuses to run as root without --allow-root; $MAKEPKG_EXTRA holds
    # that flag when we are root, and is empty otherwise.
    (cd "$tmpdir/paru" && makepkg -si --noconfirm $MAKEPKG_EXTRA)
    trap - EXIT
    rm -rf "$tmpdir"
    success "paru installed"
else
    success "paru already present"
fi

# ── 4. Core Wayland / niri stack (official repos) ────────────────────────────
info "Installing niri and core Wayland components..."
$SUDO pacman -S --needed --noconfirm \
    niri \
    xwayland-satellite \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    xdg-utils \
    wayland-utils \
    wl-clipboard \
    kanshi

# Note: wlr-randr is intentionally excluded — it only works with wlroots compositors
# (sway, wayfire, etc.). Niri does not implement wlr-output-management.
# Use 'kanshi' for display configuration or 'niri msg' for ad-hoc changes.

# ── 5. Session & display manager ─────────────────────────────────────────────
info "Installing greetd + tuigreet display manager..."
$SUDO pacman -S --needed --noconfirm greetd greetd-tuigreet

# Disable any display manager that may already be enabled to avoid boot conflicts.
for dm in sddm lightdm gdm lxdm ly; do
    if systemctl is-enabled "$dm" &>/dev/null; then
        $SUDO systemctl disable "$dm"
        info "Disabled $dm (replaced by greetd)"
    fi
done

$SUDO tee /etc/greetd/config.toml > /dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --cmd niri-session"
user = "greeter"
EOF

$SUDO systemctl enable greetd

# Add gnome-keyring PAM lines so the keyring auto-unlocks on login.
# Without this the daemon starts but the wallet stays locked until manually opened.
if ! grep -q "pam_gnome_keyring" /etc/pam.d/greetd 2>/dev/null; then
    $SUDO tee -a /etc/pam.d/greetd > /dev/null <<'EOF'
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
EOF
    info "gnome-keyring PAM lines added to /etc/pam.d/greetd"
fi

success "greetd configured"

# ── 6. Audio (pipewire assumed installed; ensure stack is complete) ────────────
info "Ensuring pipewire/wireplumber stack is complete..."
$SUDO pacman -S --needed --noconfirm \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    pipewire-jack \
    wireplumber \
    pavucontrol

# ── 7. Network & Bluetooth ────────────────────────────────────────────────────
info "Installing NetworkManager and Bluetooth..."
$SUDO pacman -S --needed --noconfirm \
    networkmanager \
    network-manager-applet \
    bluez \
    bluez-utils \
    upower

# Disable services that conflict with NetworkManager before enabling it.
# Minimal Arch installs typically enable dhcpcd on the wired interface.
for svc in dhcpcd iwd systemd-networkd; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        $SUDO systemctl disable --now "$svc"
        info "Disabled $svc (replaced by NetworkManager)"
    fi
done

$SUDO systemctl enable NetworkManager
$SUDO systemctl enable bluetooth
success "NetworkManager + Bluetooth enabled"

# ── 8. Polkit authentication agent ───────────────────────────────────────────
info "Installing polkit authentication agent..."
$SUDO pacman -S --needed --noconfirm polkit polkit-gnome

# ── 9. Fonts ──────────────────────────────────────────────────────────────────
info "Installing fonts..."
$SUDO pacman -S --needed --noconfirm \
    noto-fonts \
    noto-fonts-emoji \
    noto-fonts-cjk \
    ttf-font-awesome \
    ttf-jetbrains-mono-nerd \
    ttf-nerd-fonts-symbols

# ── 10. GTK / Qt theming tools ───────────────────────────────────────────────
info "Installing theming tools..."
$SUDO pacman -S --needed --noconfirm \
    gnome-themes-extra \
    adwaita-icon-theme \
    papirus-icon-theme \
    nwg-look \
    qt5-wayland \
    qt6-wayland \
    qt6ct \
    qt5ct

# ── 11. Terminal, launcher, file manager ─────────────────────────────────────
info "Installing terminal, launcher, and file manager..."
$SUDO pacman -S --needed --noconfirm \
    foot \
    alacritty \
    fuzzel \
    thunar \
    gvfs \
    tumbler

# ── 12. Noctalia dependencies (official repos) ───────────────────────────────
info "Installing Noctalia dependencies from official repos..."
$SUDO pacman -S --needed --noconfirm \
    brightnessctl \
    imagemagick \
    python \
    python-gobject \
    wlsunset \
    cliphist \
    power-profiles-daemon \
    evolution-data-server \
    ddcutil \
    libnotify

$SUDO systemctl enable power-profiles-daemon
success "power-profiles-daemon enabled"

# ── 13. Noctalia shell from AUR ───────────────────────────────────────────────
# noctalia-qs is a custom Quickshell fork — upstream 'quickshell' will NOT work.
# --skipreview is required for unattended runs (paru pauses for PKGBUILD diff otherwise)
info "Installing noctalia-shell via AUR (this may take a few minutes)..."
paru -S --needed --noconfirm --skipreview noctalia-shell
success "noctalia-shell installed"

# ── 14. Secrets / keyring ─────────────────────────────────────────────────────
info "Installing gnome-keyring..."
$SUDO pacman -S --needed --noconfirm gnome-keyring libsecret

# ── 15. Hardware-specific: Framework 13 AMD 7040 ─────────────────────────────
if [[ "$HARDWARE_MODE" == true ]]; then
    info "Installing Framework 13 AMD 7040 hardware packages..."

    $SUDO pacman -S --needed --noconfirm \
        vulkan-radeon \
        libva-mesa-driver \
        mesa-vdpau \
        amd-ucode \
        acpid \
        fprintd \
        fwupd

    # thermald intentionally excluded — it is Intel-only. AMD uses kernel-native
    # thermal management (k10temp driver + RAPL). No userspace daemon needed.

    $SUDO systemctl enable acpid
    $SUDO systemctl enable fwupd

    # amd-ucode only takes effect after GRUB's config is regenerated so the
    # bootloader knows to pass the microcode initrd image to the kernel.
    if command -v grub-mkconfig &>/dev/null; then
        info "Regenerating GRUB config to activate AMD microcode..."
        $SUDO grub-mkconfig -o /boot/grub/grub.cfg
    else
        warn "grub-mkconfig not found — regenerate your bootloader config manually to activate amd-ucode."
    fi

    # Framework-specific: s2idle is the correct suspend target for AMD.
    # For GRUB, add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,
    # then run: grub-mkconfig -o /boot/grub/grub.cfg
    if ! grep -q "mem_sleep_default=s2idle" /etc/default/grub 2>/dev/null; then
        warn "For proper suspend on Framework AMD, add 'mem_sleep_default=s2idle' to"
        warn "GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then run:"
        warn "  grub-mkconfig -o /boot/grub/grub.cfg"
    fi

    # AMD PSR (Panel Self Refresh) — reduces idle display power draw.
    # Use -r to safely search a possibly empty /etc/modprobe.d/
    if ! grep -qr "dcdebugmask" /etc/modprobe.d/ 2>/dev/null; then
        echo "options amdgpu dcdebugmask=0x10" | $SUDO tee /etc/modprobe.d/amdgpu-framework.conf > /dev/null
        info "AMD dcdebugmask option written (enables PSR for display power saving)"
    fi

    # ddcutil requires the i2c-dev kernel module for external monitor control.
    if ! grep -qr "i2c-dev" /etc/modules-load.d/ 2>/dev/null; then
        echo "i2c-dev" | $SUDO tee /etc/modules-load.d/i2c-dev.conf > /dev/null
        info "i2c-dev module configured for ddcutil"
    fi

    success "Hardware packages installed"
else
    warn "Skipping hardware-specific packages (use --hardware for Framework 13 AMD)"
fi

# ── 16. Niri configuration ────────────────────────────────────────────────────
NIRI_CONFIG_DIR="$HOME/.config/niri"
NIRI_CONFIG="$NIRI_CONFIG_DIR/config.kdl"

info "Writing niri config..."
mkdir -p "$NIRI_CONFIG_DIR"

if [[ ! -f "$NIRI_CONFIG" ]]; then
    cat > "$NIRI_CONFIG" <<'NIRI_CONF'
// Niri config — noctalia post-install starter
// Full reference: https://niri-wm.github.io/niri/configuration/

input {
    keyboard {
        xkb {
            layout "gb"
        }
    }

    touchpad {
        tap
        natural-scroll
        scroll-method "two-finger"
    }
}

// Spawn Noctalia shell on startup
spawn-at-startup "qs" "-c" "noctalia-shell"

// Polkit agent — full path required, binary is not in $PATH
spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"

// Keyring daemon — PAM handles auto-unlock; this ensures the daemon is running
spawn-at-startup "gnome-keyring-daemon" "--start" "--components=secrets,pkcs11,ssh"

// Clipboard history daemon
spawn-at-startup "wl-paste" "--watch" "cliphist" "store"

// Display configuration (kanshi handles multi-monitor profiles)
spawn-at-startup "kanshi"

layout {
    gaps 8
    center-focused-column "never"

    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }

    default-column-width { proportion 0.5; }

    focus-ring {
        width 2
        active-color "#7fc8ff"
        inactive-color "#505050"
    }
}

animations {
    // Uncomment to disable all animations:
    // off
}

// Key bindings — Super is the modifier
binds {
    Mod+Return { spawn "foot"; }
    Mod+Space  { spawn "fuzzel"; }
    Mod+Q      { close-window; }

    Mod+Left   { focus-column-left; }
    Mod+Right  { focus-column-right; }
    Mod+Up     { focus-window-up; }
    Mod+Down   { focus-window-down; }

    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }

    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }

    Mod+Shift+1 { move-window-to-workspace 1; }
    Mod+Shift+2 { move-window-to-workspace 2; }
    Mod+Shift+3 { move-window-to-workspace 3; }
    Mod+Shift+4 { move-window-to-workspace 4; }
    Mod+Shift+5 { move-window-to-workspace 5; }

    Mod+F       { maximize-column; }
    Mod+Shift+F { fullscreen-window; }

    // Screenshot (niri built-in)
    Print     { screenshot; }
    Mod+Print { screenshot-window; }

    // Audio (pipewire/wireplumber)
    XF86AudioRaiseVolume  { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
    XF86AudioLowerVolume  { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
    XF86AudioMute         { spawn "wpctl" "set-mute"   "@DEFAULT_AUDIO_SINK@" "toggle"; }

    // Brightness (brightnessctl)
    XF86MonBrightnessUp   { spawn "brightnessctl" "set" "5%+"; }
    XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }

    Mod+Shift+E { quit; }
}

environment {
    XDG_SESSION_TYPE        "wayland"
    XDG_SESSION_DESKTOP     "niri"
    XDG_CURRENT_DESKTOP     "niri"
    QT_QPA_PLATFORM         "wayland"
    QT_WAYLAND_DISABLE_WINDOWDECORATION "1"
    SDL_VIDEODRIVER         "wayland"
    MOZ_ENABLE_WAYLAND      "1"
    ELECTRON_OZONE_PLATFORM_HINT "wayland"
    XCURSOR_THEME           "Adwaita"
    XCURSOR_SIZE            "24"
}

// xwayland-satellite provides X11 app support — niri manages it automatically
xwayland-satellite {
}
NIRI_CONF
    success "Niri config written to $NIRI_CONFIG"
else
    warn "Niri config already exists at $NIRI_CONFIG — skipped (not overwritten)"
fi

# ── 17. System-wide environment variables (/etc/environment) ─────────────────
info "Setting system-wide environment variables..."

# Idempotent: only append the block if it isn't already present.
if ! grep -q "XDG_SESSION_DESKTOP=niri" /etc/environment 2>/dev/null; then
    $SUDO tee -a /etc/environment > /dev/null <<'EOF'

# Wayland / niri session
XDG_SESSION_TYPE=wayland
XDG_SESSION_DESKTOP=niri
XDG_CURRENT_DESKTOP=niri
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
# SDL_VIDEODRIVER intentionally omitted — setting it globally breaks SDL apps
# outside the Wayland session (games via Steam/Lutris, TTY, XWayland).
# It is set per-session inside niri's environment {} block instead.
EOF
    success "/etc/environment updated"
else
    success "/etc/environment already configured — skipped"
fi

# ── 18. niri-session wrapper ──────────────────────────────────────────────────
# greetd needs an executable named 'niri-session' on PATH; 'niri --session'
# is the correct invocation for a full login session with D-Bus activation.
if [[ ! -f /usr/local/bin/niri-session ]]; then
    info "Creating niri-session wrapper..."
    $SUDO tee /usr/local/bin/niri-session > /dev/null <<'EOF'
#!/bin/sh
exec niri --session
EOF
    $SUDO chmod +x /usr/local/bin/niri-session
    success "niri-session wrapper created"
else
    success "niri-session wrapper already exists — skipped"
fi

# ── 19. XDG portal config for niri ───────────────────────────────────────────
info "Configuring XDG portals for niri..."
mkdir -p "$HOME/.config/xdg-desktop-portal"

# Portal resolution order: gnome portal (screensharing) → gtk portal (file picker etc.)
# File is named after XDG_CURRENT_DESKTOP so xdg-desktop-portal picks it up automatically.
cat > "$HOME/.config/xdg-desktop-portal/niri-portals.conf" <<'EOF'
[preferred]
default=gnome;gtk
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF
success "Portal config written"

# ── 20. User group membership ─────────────────────────────────────────────────
# Only meaningful for real user accounts; skip when running as root.
if [[ -n "$TARGET_USER" ]]; then
    info "Adding $TARGET_USER to video and input groups..."
    $SUDO usermod -aG video,input "$TARGET_USER"
    success "$TARGET_USER added to video and input groups (effective on next login)"
else
    warn "Skipping group membership step (running as root — apply to your user account manually)."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  What was installed:"
echo "   • niri (Wayland compositor) + kanshi (display config)"
echo "   • noctalia-shell + noctalia-qs (AUR)"
echo "   • greetd + tuigreet (display manager)"
echo "   • xwayland-satellite (X11 app support)"
echo "   • NetworkManager, Bluetooth, PipeWire, fonts, theming"
echo "   • qt5-wayland + qt6-wayland (native Wayland for Qt apps)"
[[ "$HARDWARE_MODE" == true ]] && echo "   • Framework 13 AMD 7040 hardware packages"
echo ""
echo "  Next steps:"
echo "   1. Reboot"
echo "   2. Log in via greetd — niri session starts automatically"
echo "   3. Noctalia shell launches automatically via niri config"
echo "   4. Customise ~/.config/niri/config.kdl for keybinds/layout"
echo "   5. Set GTK theme:  nwg-look"
echo "      Set Qt theme:   qt6ct"
echo ""
if [[ -z "$TARGET_USER" ]]; then
    echo -e "  ${YELLOW}You ran as root. Before rebooting:${NC}"
    echo "   • Create a user:  useradd -m -G wheel,video,input -s /bin/bash USERNAME"
    echo "   • Set password:   passwd USERNAME"
    echo "   • Install sudo:   pacman -S sudo"
    echo "   • Edit sudoers:   EDITOR=nano visudo  (uncomment %wheel line)"
    echo ""
fi
if [[ "$HARDWARE_MODE" == false ]]; then
    echo -e "  ${YELLOW}When moving to Framework 13 AMD:${NC}"
    echo "   Run again with:  ./arch-niri-noctalia.sh --hardware"
    echo "   (or:  bash <(curl -fsSL RAW_URL) --hardware)"
    echo ""
fi
