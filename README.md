# Raspberry Pi USB Web Kiosk Setup

Automated setup script for configuring a Raspberry Pi as a web kiosk with USB hotswap functionality.

## Features

- **Dynamic Web Server**: Serves content from USB (`/media/usb/www`) when present, falls back to `/var/www/html`
- **Chromium Kiosk Mode**: Fullscreen browser that auto-starts on boot
- **Dynamic Display Rotation**: Configure rotation via USB config file (0°, 90°, 180°, 270°)
- **Touch Mouse Emulation**: Configure touch-to-mouse emulation via USB config file
- **Auto Cursor Hide**: Cursor automatically hides after startup
- **USB Hotswap**: Automatically reloads content when USB drives are inserted/removed
- **Custom Boot Splash**: Custom boot screen image

## Prerequisites

- Raspberry Pi running Raspberry Pi OS (Tested on Trixie)
- Root/sudo access
- Internet connection for initial setup

## Quick Start

```bash
curl -sL https://raw.githubusercontent.com/wearelucid/rpi-usb-webkiosk/refs/heads/main/setup-usb-web.sh | sudo bash
```

Or with a custom user:

```bash
curl -sL https://raw.githubusercontent.com/wearelucid/rpi-usb-webkiosk/refs/heads/main/setup-usb-web.sh | TARGET_USER=pi sudo bash
```

## Configuration

### Default User

By default, the script configures everything for the `lucid` user. To use a different user:

```bash
curl -sL https://raw.githubusercontent.com/wearelucid/rpi-usb-webkiosk/refs/heads/main/setup-usb-web.sh | TARGET_USER=pi sudo bash
```

### USB Configuration File

Create a `KIOSK_CONFIG.txt` file on your USB drive to customize behavior:

```
/media/usb/KIOSK_CONFIG.txt
```

**Display Rotation:**

Add this line to set display rotation:

```
ROTATION=90
```

Valid values: `0` (landscape), `90` (portrait), `180` (upside down), `270` (portrait flipped)

**Touch Mouse Emulation:**

Add this line to enable or disable touch-to-mouse emulation:

```
MOUSE_EMULATION=yes
```

Valid values: `yes` (enabled, default), `no` (disabled)

**Example:**

```bash
# On your USB drive, create /KIOSK_CONFIG.txt with:
cat > /media/usb/KIOSK_CONFIG.txt <<EOF
ROTATION=90
MOUSE_EMULATION=yes
EOF
```

## USB Drive Setup

### Web Content

Place your website files in a `www` directory on your USB drive:

```
USB Drive/
├── www/
│   ├── index.html
│   ├── css/
│   ├── js/
│   └── images/
└── KIOSK_CONFIG.txt
```

The web server will automatically serve from `/media/usb/www` when the USB is inserted.

## Post-Installation

### Reboot

After installation, reboot to activate all features:

```bash
sudo reboot
```
