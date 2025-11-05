#!/usr/bin/env bash
#
# Raspberry Pi Kiosk Setup Script
# ================================
# Configures Lighttpd to serve /media/usb/www (when USB is present) or /var/www/html (fallback).
# Sets up Chromium in kiosk mode with dynamic display rotation and cursor hiding.
# Automatically reloads when USB drives are mounted/unmounted.
#
# Usage: sudo bash setup-usb-web.sh
#        TARGET_USER=pi sudo bash setup-usb-web.sh
#
set -euo pipefail

TARGET_USER="${TARGET_USER:-lucid}"
USB_DOCROOT="/media/usb/www"
DEFAULT_DOCROOT="/var/www/html"
USB_KIOSK_CONFIG="/media/usb/KIOSK_CONFIG"

SHELL_HELPER="/usr/local/bin/lighttpd-usbroot.sh"
LIGHTTPD_CONF_DIR="/etc/lighttpd"
DYNAMIC_CONF="${LIGHTTPD_CONF_DIR}/conf-available/10-dynamic-docroot.conf"

USBMOUNT_CONF="/etc/usbmount/usbmount.conf"
MOUNT_HOOK_DIR="/etc/usbmount/mount.d"
UMOUNT_HOOK_DIR="/etc/usbmount/umount.d"

KANSHI_HELPER="/usr/local/bin/update-kanshi-rotation.sh"

echo "======================================="
echo " USB Web Kiosk Setup"
echo "======================================="

# ========================================
# [1/11] Install Base Packages
# ========================================
echo "[1/11] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y lighttpd acl exfatprogs exfat-fuse wtype

# ========================================
# [2/11] Install usbmount
# ========================================
if dpkg-query -W -f='${Status}' usbmount 2>/dev/null | grep -q "install ok installed"; then
  echo "[2/11] usbmount already installed."
else
  echo "[2/11] Building usbmount from source..."
  apt-get install -y git debhelper build-essential

  cd /tmp
  rm -rf usbmount || true
  git clone https://github.com/rbrito/usbmount.git
  cd usbmount

  dpkg-buildpackage -us -uc -b
  cd ..

  # install the built .deb
  dpkg -i ./usbmount_*_all.deb

  echo "usbmount installed."
fi

# ========================================
# [3/11] Create Lighttpd Docroot Resolver
# ========================================
echo "[3/11] Creating docroot resolver script..."

cat > "${SHELL_HELPER}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ -d /media/usb/www ]; then
  printf 'var.dynamic_docroot = "/media/usb/www"\n'
else
  printf 'var.dynamic_docroot = "/var/www/html"\n'
fi
SH

chmod +x "${SHELL_HELPER}"
sed -i 's/\r$//' "${SHELL_HELPER}"

# ========================================
# [4/11] Configure Lighttpd
# ========================================
echo "[4/11] Configuring Lighttpd..."

# Remove any old/conflicting configurations
rm -f "${LIGHTTPD_CONF_DIR}/conf-available/99-usb-docroot.conf"
rm -f "${LIGHTTPD_CONF_DIR}/conf-enabled/99-usb-docroot.conf"
rm -f "${LIGHTTPD_CONF_DIR}/conf-enabled/10-dynamic-docroot.conf"

mkdir -p "$(dirname "${DYNAMIC_CONF}")"
cat > "${DYNAMIC_CONF}" <<CONF
include_shell "${SHELL_HELPER}"
server.document-root = var.dynamic_docroot
CONF

# Disable default server.document-root if present (avoid duplicates)
sed -i -E '/^[[:space:]]*#.*server\.document-root.*disabled by usb kiosk/d' "${LIGHTTPD_CONF_DIR}/lighttpd.conf" || true
sed -i -E 's/^[[:space:]]*server\.document-root.*/# server.document-root disabled by usb kiosk/' \
  "${LIGHTTPD_CONF_DIR}/lighttpd.conf" || true

ln -sf ../conf-available/10-dynamic-docroot.conf "${LIGHTTPD_CONF_DIR}/conf-enabled/10-dynamic-docroot.conf"

lighttpd -tt -f "${LIGHTTPD_CONF_DIR}/lighttpd.conf"
systemctl reload lighttpd || systemctl restart lighttpd

# ========================================
# [5/11] Create Default Index Page
# ========================================
echo "[5/11] Creating default index page..."
mkdir -p "${DEFAULT_DOCROOT}"
if [ ! -f "${DEFAULT_DOCROOT}/index.html" ]; then
  cat > "${DEFAULT_DOCROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>No USB Content</title>
<style>
  body{margin:0;padding:0;font-family:sans-serif;background:#111;color:#eee;display:flex;flex-direction:column;justify-content:center;align-items:center;height:100vh;text-align:center}
  h1{font-size:2.2rem;margin:.2rem 0}
  p{opacity:.85;max-width:420px}
  code{background:rgba(255,255,255,.12);padding:.2rem .4rem;border-radius:4px}
</style></head>
<body>
  <h1>No USB detected</h1>
  <p>Insert a USB drive and place your website files inside:<br><br><code>/www</code></p>
</body></html>
HTML
  chown www-data:www-data "${DEFAULT_DOCROOT}/index.html"
fi

# ========================================
# [6/11] Configure Permissions
# ========================================
echo "[6/11] Configuring permissions..."

usermod -aG www-data "${TARGET_USER}" || true
chgrp -R www-data /var/www
find /var/www -type d -exec chmod 2775 {} \;
find /var/www -type f -exec chmod 664 {} \;
setfacl -R -m g:www-data:rwx /var/www || true
setfacl -d -m g:www-data:rwx /var/www || true

# ========================================
# [7/11] Configure usbmount & USB Hooks
# ========================================
echo "[7/11] Configuring USB mount hooks..."
# Configure usbmount filesystems and mount options
sed -i -E 's@^#?[[:space:]]*FILESYSTEMS=.*@FILESYSTEMS="vfat ext2 ext3 ext4 ntfs exfat"@' "${USBMOUNT_CONF}"
sed -i -E 's@^MOUNTOPTIONS=.*@MOUNTOPTIONS="sync,noexec,nodev,noatime,uid=33,gid=33,umask=002"@' "${USBMOUNT_CONF}" \
  || echo 'MOUNTOPTIONS="sync,noexec,nodev,noatime,uid=33,gid=33,umask=002"' >> "${USBMOUNT_CONF}"

# Create mount/unmount hooks
mkdir -p "${MOUNT_HOOK_DIR}" "${UMOUNT_HOOK_DIR}"

cat > "${MOUNT_HOOK_DIR}/20-reload-lighttpd" <<SH
#!/usr/bin/env bash
killall -q chromium || true
killall -q chromium-browser || true
systemctl reload lighttpd || true

# Update display rotation based on USB config
/usr/local/bin/update-kanshi-rotation.sh ${TARGET_USER} || true
SH

cat > "${UMOUNT_HOOK_DIR}/20-reload-lighttpd" <<SH
#!/usr/bin/env bash
killall -q chromium || true
killall -q chromium-browser || true
systemctl reload lighttpd || true

# Reset display rotation to default (0) when USB is removed
/usr/local/bin/update-kanshi-rotation.sh ${TARGET_USER} || true
SH

chmod +x "${MOUNT_HOOK_DIR}/20-reload-lighttpd"
chmod +x "${UMOUNT_HOOK_DIR}/20-reload-lighttpd"

# Reload udev rules
udevadm control --reload-rules || true
udevadm trigger || true

# ========================================
# [8/11] Configure Labwc & Desktop
# ========================================
echo "[8/11] Configuring labwc window manager..."

TARGET_HOME=$(eval echo "~${TARGET_USER}")
LABWC_CONFIG_DIR="${TARGET_HOME}/.config/labwc"
mkdir -p "${LABWC_CONFIG_DIR}"

cat > "${LABWC_CONFIG_DIR}/rc.xml" <<'XML'
<?xml version="1.0"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <!-- Adds the Shortcut Alt-Logo-h to hide the Cursor -->
  <keyboard>
    <keybind key="A-W-h">
      <action name="HideCursor" />
      <action name="WarpCursor" x="-1" y="-1" />
    </keybind>
  </keyboard>
</openbox_config>
XML

chown -R "${TARGET_USER}:${TARGET_USER}" "${LABWC_CONFIG_DIR}"

# Disable Raspberry Pi Desktop components
SYSTEM_LABWC_AUTOSTART="/etc/xdg/labwc/autostart"
if [ -f "${SYSTEM_LABWC_AUTOSTART}" ]; then
  # Backup original
  cp "${SYSTEM_LABWC_AUTOSTART}" "${SYSTEM_LABWC_AUTOSTART}.bak"
  
  # Disable desktop components, keep kanshi enabled
  sed -i 's@^\(/usr/bin/lwrespawn /usr/bin/pcmanfm --desktop --profile LXDE-pi &\)@#\1@' "${SYSTEM_LABWC_AUTOSTART}"
  sed -i 's@^\(/usr/bin/lwrespawn /usr/bin/wf-panel-pi &\)@#\1@' "${SYSTEM_LABWC_AUTOSTART}"
  sed -i 's@^\(/usr/bin/lxsession-xdg-autostart\)@#\1@' "${SYSTEM_LABWC_AUTOSTART}"
  
  # Ensure kanshi is enabled and configured with the exact line
  if ! grep -q "^/usr/bin/lwrespawn /usr/bin/kanshi &$" "${SYSTEM_LABWC_AUTOSTART}"; then
    echo "/usr/bin/lwrespawn /usr/bin/kanshi &" >> "${SYSTEM_LABWC_AUTOSTART}"
  fi
  
  echo "Desktop components disabled."
else
  echo "Warning: ${SYSTEM_LABWC_AUTOSTART} not found."
fi

# ========================================
# [9/11] Configure Chromium Kiosk
# ========================================
echo "[9/11] Configuring Chromium kiosk..."

cat > "${LABWC_CONFIG_DIR}/autostart" <<'AUTOSTART'
# Chromium kiosk mode
/usr/bin/lwrespawn chromium \
	--noerrdialogs \
	--disable-session-crashed-bubble \
	--disable-infobars \
	--start-maximized \
	--incognito \
	--kiosk http://localhost &

# Hide cursor using wtype to send Alt-Logo-h shortcut
wtype -M alt -M logo h -m alt -m logo &
AUTOSTART

chown "${TARGET_USER}:${TARGET_USER}" "${LABWC_CONFIG_DIR}/autostart"
chmod +x "${LABWC_CONFIG_DIR}/autostart"

# ========================================
# [10/11] Configure Display Rotation
# ========================================
echo "[10/11] Configuring display rotation..."

KANSHI_CONFIG_DIR="${TARGET_HOME}/.config/kanshi"
mkdir -p "${KANSHI_CONFIG_DIR}"

# Create rotation helper script
cat > "${KANSHI_HELPER}" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${1:-lucid}"
TARGET_HOME=$(eval echo "~${TARGET_USER}")
KANSHI_CONFIG="${TARGET_HOME}/.config/kanshi/config"
USB_CONFIG="/media/usb/KIOSK_CONFIG"

# Default rotation
ROTATION=0

# Read rotation from USB config if it exists
if [ -f "${USB_CONFIG}" ]; then
  # Source the config file safely
  if grep -q "^ROTATION=" "${USB_CONFIG}"; then
    ROTATION=$(grep "^ROTATION=" "${USB_CONFIG}" | head -n1 | cut -d'=' -f2 | tr -d ' "'"'"'')
  fi
fi

# Validate rotation value (0, 90, 180, 270) and map to kanshi transform
case "${ROTATION}" in
  0)
    TRANSFORM="normal"
    ;;
  90)
    TRANSFORM="90"
    ;;
  180)
    TRANSFORM="180"
    ;;
  270)
    TRANSFORM="270"
    ;;
  *)
    echo "Warning: Invalid rotation value '${ROTATION}', using default (normal)"
    ROTATION=0
    TRANSFORM="normal"
    ;;
esac

# Generate kanshi config
mkdir -p "$(dirname "${KANSHI_CONFIG}")"
cat > "${KANSHI_CONFIG}" <<KANSHI
profile kiosk {
	output HDMI-A-1 enable transform ${TRANSFORM}
}
KANSHI

chown "${TARGET_USER}:${TARGET_USER}" "${KANSHI_CONFIG}"

echo "Display rotation set to ${ROTATION}° (transform: ${TRANSFORM})"

# Reload kanshi if it's running
if pgrep -x kanshi > /dev/null; then
  pkill -HUP kanshi || true
fi
HELPER

chmod +x "${KANSHI_HELPER}"

# Run helper to create initial config
"${KANSHI_HELPER}" "${TARGET_USER}"

# ========================================
# [11/11] Configure Boot Splash Screen
# ========================================
echo "[11/11] Configuring boot splash screen..."

# Install plymouth if not present
if ! command -v plymouth > /dev/null 2>&1; then
  echo "Installing plymouth..."
  apt-get install -y plymouth plymouth-themes
fi

# Download boot splash image
BOOT_SPLASH_URL="https://raw.githubusercontent.com/wearelucid/rpi-usb-webkiosk/refs/heads/main/boot.png"
PLYMOUTH_THEME_DIR="/usr/share/plymouth/themes/pix"
PLYMOUTH_SPLASH="${PLYMOUTH_THEME_DIR}/splash.png"

mkdir -p "${PLYMOUTH_THEME_DIR}"

echo "Downloading boot splash image..."
DOWNLOAD_SUCCESS=false

if command -v curl > /dev/null 2>&1; then
  if curl -L -f -o "${PLYMOUTH_SPLASH}" "${BOOT_SPLASH_URL}" 2>/dev/null; then
    DOWNLOAD_SUCCESS=true
  fi
elif command -v wget > /dev/null 2>&1; then
  if wget -q -O "${PLYMOUTH_SPLASH}" "${BOOT_SPLASH_URL}" 2>/dev/null; then
    DOWNLOAD_SUCCESS=true
  fi
else
  echo "Installing curl..."
  apt-get install -y curl
  if curl -L -f -o "${PLYMOUTH_SPLASH}" "${BOOT_SPLASH_URL}" 2>/dev/null; then
    DOWNLOAD_SUCCESS=true
  fi
fi

if [ "${DOWNLOAD_SUCCESS}" = false ]; then
  echo "Warning: Failed to download boot splash image. Skipping..."
else
  echo "Boot splash image downloaded successfully."
  
  # Set Plymouth theme and rebuild initrd
  echo "Setting Plymouth theme..."
  plymouth-set-default-theme pix || true
  plymouth-set-default-theme --rebuild-initrd pix || {
    echo "Warning: Failed to rebuild initrd. Boot splash may not work."
  }
fi

# ========================================
# Setup Complete
# ========================================
echo ""
echo "✅ SETUP COMPLETE"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Target user:    ${TARGET_USER}"
echo "  Default web:    ${DEFAULT_DOCROOT}"
echo "  USB web:        ${USB_DOCROOT}"
echo "  USB config:     ${USB_KIOSK_CONFIG}"
echo ""
echo "Features:"
echo "  • Chromium kiosk (localhost)"
echo "  • Auto cursor hide (Alt+Logo+H)"
echo "  • Dynamic rotation via USB"
echo "  • USB hotswap auto-reload"
echo "  • Custom boot splash screen"
echo ""
echo "USB Configuration:"
echo "  Create ${USB_KIOSK_CONFIG} with:"
echo "    ROTATION=90    (0, 90, 180, 270)"
echo ""
echo "Next Steps:"
echo "  1. Reboot or restart Wayland"
echo "  2. Test USB mount/unmount"
echo "  3. Place web files in /www on USB"
echo ""
echo "=========================================="
