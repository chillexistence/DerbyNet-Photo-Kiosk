#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

#####################################################################################
# Use this on Windows from PowerShell to copy the zip & install to the Pi:
# scp "C:\path\to\photostation_v3.1.1.zip" admin@PI_IP:/home/admin/
# scp "C:\path\to\photostation_install.sh" admin@PI_IP:/home/admin/
# Then run from SSH connected to the Pi:
# chmod +x /home/admin/photostation_install.sh
# sudo bash /home/admin/photostation_install.sh "/home/admin/photostation_v3.1.1.zip"
#####################################################################################


SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_PATH=""
ASSUME_YES=0
AUDIO_CHOICE=""

log()  { printf '\n[%s] %s\n' "INFO" "$*"; }
warn() { printf '\n[%s] %s\n' "WARN" "$*" >&2; }
fail() { printf '\n[%s] %s\n' "ERROR" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n[ERROR] %s failed at line %s.\n' "$SCRIPT_NAME" "$1" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<EOF
Usage:
  sudo bash $SCRIPT_NAME [photostation_package.tar.gz] [--yes] [--audio hdmi1|hdmi2|hdmi|jack|headphones]

Examples:
  sudo bash $SCRIPT_NAME
  sudo bash $SCRIPT_NAME /home/admin/photostation_package.tar.gz
  sudo bash $SCRIPT_NAME --yes --audio hdmi2
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --audio)
      [[ $# -ge 2 ]] || fail "--audio requires a value"
      AUDIO_CHOICE="$2"
      shift 2
      ;;
    --audio=*)
      AUDIO_CHOICE="${1#*=}"
      shift
      ;;
    --*)
      fail "Unknown option: $1"
      ;;
    *)
      if [[ -z "$PACKAGE_PATH" ]]; then
        PACKAGE_PATH="$1"
      else
        fail "Only one package path may be provided"
      fi
      shift
      ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "Run this installer as root"

if [[ -z "$PACKAGE_PATH" ]]; then
  if [[ -f "$SCRIPT_DIR/photostation_package.tar.gz" ]]; then
    PACKAGE_PATH="$SCRIPT_DIR/photostation_package.tar.gz"
  elif [[ -f "$SCRIPT_DIR/photostation_package.zip" ]]; then
    PACKAGE_PATH="$SCRIPT_DIR/photostation_package.zip"
  else
    fail "No package specified and no photostation_package.tar.gz found next to the installer"
  fi
fi
[[ -f "$PACKAGE_PATH" ]] || fail "Package not found: $PACKAGE_PATH"

ADMIN_USER="admin"
ADMIN_HOME="/home/${ADMIN_USER}"
SERVICE_NAME="photostation.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
INSTALL_ROOT="/opt/photostation"
WEB_ROOT="/var/www/html"
PHOTO_WEB_ROOT="${WEB_ROOT}/photostation"
DESKTOP_AUTOSTART="${ADMIN_HOME}/.config/autostart/chromium-launcher.desktop"
START_SCRIPT="${ADMIN_HOME}/start-photostation.sh"
SUDOERS_FILE="/etc/sudoers.d/photostation"
LIGHTDM_AUTLOGIN_DIR="/etc/lightdm/lightdm.conf.d"
LIGHTDM_AUTLOGIN_FILE="${LIGHTDM_AUTLOGIN_DIR}/99-photostation-autologin.conf"
ASOUND_FILE="/etc/asound.conf"

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

PI_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
if [[ -z "$PI_MODEL" ]]; then
  PI_MODEL="$(uname -a)"
fi
log "Detected platform: ${PI_MODEL}"

backup_existing_install() {
  local stamp archive
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="/root/photostation-preinstall-backup-${stamp}.tar.gz"
  local items=()
  [[ -d "$INSTALL_ROOT" ]] && items+=("$INSTALL_ROOT")
  [[ -d "$PHOTO_WEB_ROOT" ]] && items+=("$PHOTO_WEB_ROOT")
  [[ -f "$WEB_ROOT/launcher.html" ]] && items+=("$WEB_ROOT/launcher.html")
  [[ -f "$WEB_ROOT/index.html" ]] && items+=("$WEB_ROOT/index.html")
  [[ -f "$SERVICE_FILE" ]] && items+=("$SERVICE_FILE")
  [[ -f "$SUDOERS_FILE" ]] && items+=("$SUDOERS_FILE")

  if ((${#items[@]})); then
    log "Backing up any existing install to ${archive}"
    tar czf "$archive" "${items[@]}"
  fi
}

confirm_wipe() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi

  cat <<EOF

This installer will:
  - remove any existing PhotoStation app files
  - redeploy /opt/photostation and /var/www/html/photostation
  - replace ${SERVICE_FILE}
  - replace ${SUDOERS_FILE}
  - configure LightDM autologin for ${ADMIN_USER}
  - configure Chromium kiosk autostart
EOF
  read -r -p "Continue with a wipe-and-reinstall? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Aborted by user"
}

wipe_existing_install() {
  log "Removing existing PhotoStation install"
  systemctl stop photostation.service 2>/dev/null || true
  pkill -f 'chromium.*launcher.html' 2>/dev/null || true
  rm -rf "$INSTALL_ROOT" "$PHOTO_WEB_ROOT"
  rm -f "$WEB_ROOT/launcher.html" "$WEB_ROOT/index.html"
  rm -f "$SERVICE_FILE" "$SUDOERS_FILE"
  rm -f "$DESKTOP_AUTOSTART" "$START_SCRIPT"
}

ensure_admin_user() {
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    log "Creating local user ${ADMIN_USER}"
    useradd -m -s /bin/bash "$ADMIN_USER"

    if [[ "$ASSUME_YES" == "0" ]]; then
      echo
      echo "The ${ADMIN_USER} account did not exist."
      echo "Set a password now if you want local console/shell login for that user."
      echo "Press Enter on an empty prompt to skip password creation for now."
      read -r -s -p "New password for ${ADMIN_USER} (optional): " pw1
      echo
      if [[ -n "$pw1" ]]; then
        read -r -s -p "Re-enter password: " pw2
        echo
        [[ "$pw1" == "$pw2" ]] || fail "Passwords did not match"
        echo "${ADMIN_USER}:${pw1}" | chpasswd
      else
        warn "No password set for ${ADMIN_USER}. Run 'sudo passwd ${ADMIN_USER}' later if needed."
      fi
    else
      warn "${ADMIN_USER} was created without setting a password. Run 'sudo passwd ${ADMIN_USER}' later if desired."
    fi
  fi

  usermod -aG sudo,video,plugdev,input,audio "$ADMIN_USER"
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

choose_browser_package() {
    if apt-cache show chromium >/dev/null 2>&1; then
        echo "chromium"
    elif apt-cache show chromium-browser >/dev/null 2>&1; then
        echo "chromium-browser"
    else
        return 1
    fi
}

install_packages() {
  log "Updating apt metadata"
  apt-get update

  local browser_pkg
  browser_pkg="$(choose_browser_package)" || fail "No Chromium package was found in apt"

  local common_packages=(
    apache2
    php
    libapache2-mod-php
    curl
    jq
    imagemagick
    fswebcam
    gphoto2
    python3
    sudo
    ca-certificates
    rsync
    unzip
    p7zip-full
    x11-xserver-utils
    unclutter
    fonts-noto-color-emoji
    sox
    espeak-ng
	mbrola mbrola-us1
    alsa-utils
	pipewire-audio-client-libraries
    pulseaudio-utils
    util-linux
    "$browser_pkg"
  )

  local desktop_packages=(
    lightdm
    xserver-xorg
    lxsession
    openbox
    raspberrypi-ui-mods
  )

  log "Installing core packages"
  apt_install "${common_packages[@]}"

  if [[ ! -x /usr/sbin/lightdm || ! -d /usr/share/xsessions ]]; then
    log "Desktop stack not fully present; installing LightDM/X11 desktop packages"
    apt_install "${desktop_packages[@]}"
  else
    log "LightDM/X11 desktop stack already present"
  fi

  if pkg_available mbrola; then
    apt_install mbrola || true
  fi
  if pkg_available mbrola-us1; then
    apt_install mbrola-us1 || true
  fi
}

extract_package() {
  log "Extracting package: ${PACKAGE_PATH}"
  case "$PACKAGE_PATH" in
    *.tar.gz|*.tgz)
      tar xzf "$PACKAGE_PATH" -C "$TMPDIR"
      ;;
    *.zip)
      unzip -q "$PACKAGE_PATH" -d "$TMPDIR"
      ;;
    *)
      fail "Unsupported package type. Use .tar.gz, .tgz, or .zip"
      ;;
  esac

  [[ -f "$TMPDIR/opt/photostation/photostation.sh" ]] || fail "Package missing opt/photostation/photostation.sh"
  [[ -f "$TMPDIR/var/www/html/launcher.html" ]] || fail "Package missing var/www/html/launcher.html"
  [[ -f "$TMPDIR/etc/systemd/system/photostation.service" ]] || fail "Package missing etc/systemd/system/photostation.service"
}

choose_audio() {
  local normalized="${AUDIO_CHOICE,,}"
  if [[ -n "$normalized" ]]; then
    case "$normalized" in
      hdmi1|hdmi2|hdmi|jack|headphones|3.5mm|35mm)
        :
        ;;
      *)
        fail "Invalid --audio value: ${AUDIO_CHOICE}"
        ;;
    esac
    AUDIO_CHOICE="$normalized"
    return 0
  fi

  echo
  echo "Select audio output for kiosk sounds and speech:"
  if [[ "$PI_MODEL" =~ Raspberry\ Pi\ [45] ]]; then
    echo "  1) HDMI 1 (Left)"
    echo "  2) HDMI 2 (Right)"
    echo "  3) 3.5mm / headphones"
	echo "  4) No audio"
    read -r -p "Choice [1-4]: " choice
    case "$choice" in
      1) AUDIO_CHOICE="hdmi1" ;;
      2) AUDIO_CHOICE="hdmi2" ;;
      3) AUDIO_CHOICE="jack" ;;
	  4) AUDIO_CHOICE="none" ;;
      *) fail "Invalid audio choice" ;;
    esac
  else
    echo "  1) HDMI"
    echo "  2) 3.5mm / headphones"
	echo "  3) No audio"
    read -r -p "Choice [1-3]: " choice
    case "$choice" in
      1) AUDIO_CHOICE="hdmi" ;;
      2) AUDIO_CHOICE="jack" ;;
	  3) AUDIO_CHOICE="none" ;;
      *) fail "Invalid audio choice" ;;
    esac
  fi
}

resolve_audio_device() {
  local selection="$1"
  local devices
  devices="$(aplay -L 2>/dev/null || true)"

  case "$selection" in
    none)
      printf 'none\n'
      ;;

    hdmi1)
      grep -m1 '^hdmi:CARD=vc4hdmi0,DEV=0$' <<<"$devices" \
        || grep -m1 '^hdmi:CARD=.*hdmi0.*DEV=0$' <<<"$devices" \
        || grep -m1 '^hdmi:CARD=vc4hdmi,DEV=0$' <<<"$devices" \
        || grep -m1 '^hdmi:' <<<"$devices" \
        || true
      ;;

    hdmi2)
      grep -m1 '^hdmi:CARD=vc4hdmi1,DEV=0$' <<<"$devices" \
        || grep -m1 '^hdmi:CARD=.*hdmi1.*DEV=0$' <<<"$devices" \
        || grep -m1 '^hdmi:' <<<"$devices" \
        || true
      ;;

    hdmi)
      if grep -q connected /sys/class/drm/*HDMI-A-1/status 2>/dev/null; then
        grep -m1 '^hdmi:CARD=vc4hdmi0,DEV=0$' <<<"$devices" \
          || grep -m1 '^hdmi:CARD=vc4hdmi,DEV=0$' <<<"$devices" \
          || true
      elif grep -q connected /sys/class/drm/*HDMI-A-2/status 2>/dev/null; then
        grep -m1 '^hdmi:CARD=vc4hdmi1,DEV=0$' <<<"$devices" \
          || true
      else
        grep -m1 '^hdmi:' <<<"$devices" || true
      fi
      ;;

    jack|headphones|3.5mm|35mm)
      grep -m1 '^plughw:CARD=.*Headphones' <<<"$devices" \
        || grep -m1 '^sysdefault:CARD=.*Headphones' <<<"$devices" \
        || grep -m1 '^front:CARD=.*Headphones' <<<"$devices" \
        || true
      ;;

    *)
      fail "Unknown audio selection: ${selection}"
      ;;
  esac
}

configure_audio() {
  choose_audio

  local audio_device=""
  local raspi_audio=""

  case "$AUDIO_CHOICE" in
    none) raspi_audio="" ;;
    hdmi1|hdmi2|hdmi) raspi_audio='1' ;;
    jack|headphones|3.5mm|35mm) raspi_audio='0' ;;
    *) raspi_audio='1' ;;
  esac

  audio_device="$(resolve_audio_device "$AUDIO_CHOICE")"
	# Convert HDMI ALSA string to plughw so mono/stereo conversion works
	if [[ "$audio_device" =~ CARD=([^,]+),DEV=([0-9]+) ]]; then
	  card="${BASH_REMATCH[1]}"
	  dev="${BASH_REMATCH[2]}"

	  # get numeric card index
	  card_index="$(aplay -l | awk -v c="$card" '$0 ~ c {gsub("card ",""); gsub(":",""); print $1; exit}')"

	  if [[ -n "$card_index" ]]; then
		audio_device="plughw:${card_index},${dev}"
	  fi
	fi
	
  if [[ "$AUDIO_CHOICE" == "none" ]]; then
    log "Audio disabled by installer selection"
    if grep -q '^AUDIO_DEVICE=' "$INSTALL_ROOT/config.conf"; then
      sed -i 's|^AUDIO_DEVICE=.*|AUDIO_DEVICE="none"|' "$INSTALL_ROOT/config.conf"
    else
      echo 'AUDIO_DEVICE="none"' >> "$INSTALL_ROOT/config.conf"
    fi
    return 0
  fi

  if [[ -z "$audio_device" ]]; then
    warn "Could not auto-detect an ALSA device for '${AUDIO_CHOICE}'."
    echo
    echo "Detected playback devices:"
    echo "----------------------------------------"
    aplay -L || true
    echo "----------------------------------------"
    read -r -p 'Enter the exact ALSA device string to use (example: hdmi:CARD=vc4hdmi1,DEV=0): ' audio_device
    [[ -n "$audio_device" ]] || fail "No ALSA device entered"
  fi

  log "Configuring audio: selection=${AUDIO_CHOICE}, device=${audio_device}"

  if command -v raspi-config >/dev/null 2>&1 && [[ -n "$raspi_audio" ]]; then
    raspi-config nonint do_audio "$raspi_audio" || true
  fi

  if grep -q '^AUDIO_DEVICE=' "$INSTALL_ROOT/config.conf"; then
    sed -i "s|^AUDIO_DEVICE=.*|AUDIO_DEVICE=\"$audio_device\"|" "$INSTALL_ROOT/config.conf"
  else
    echo "AUDIO_DEVICE=\"$audio_device\"" >> "$INSTALL_ROOT/config.conf"
  fi
 
 if command -v espeak-ng >/dev/null 2>&1; then
    if ! espeak-ng --voices 2>/dev/null | grep -qE '(^|[[:space:]])mb-us1([[:space:]]|$)'; then
	  warn "mb-us1 voice is not installed. Install it with: sudo apt install mbrola mbrola-us1"
	fi
  fi


  speaker-test -D "$audio_device" -t sine -f 880 -l 1 >/dev/null 2>&1 || true
}

configure_lightdm_autologin() {
  log "Configuring LightDM autologin for ${ADMIN_USER}"
  mkdir -p "$LIGHTDM_AUTLOGIN_DIR"
  cat > "$LIGHTDM_AUTLOGIN_FILE" <<EOF
[Seat:*]
autologin-user=${ADMIN_USER}
autologin-user-timeout=0
EOF

  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_boot_behaviour B4 || true
  fi

  systemctl enable lightdm >/dev/null 2>&1 || true
  systemctl set-default graphical.target >/dev/null 2>&1 || true
}

install_app_files() {
  log "Deploying PhotoStation files"
  install -d -m 0775 -o "$ADMIN_USER" -g www-data "$INSTALL_ROOT"
  install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$INSTALL_ROOT/work"
  install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$PHOTO_WEB_ROOT"

  rsync -a "$TMPDIR/opt/photostation/" "$INSTALL_ROOT/"
  rsync -a "$TMPDIR/var/www/html/photostation/" "$PHOTO_WEB_ROOT/"
  install -m 0644 "$TMPDIR/var/www/html/launcher.html" "$WEB_ROOT/launcher.html"
  install -m 0644 "$TMPDIR/etc/systemd/system/photostation.service" "$SERVICE_FILE"

  local desktop_dir="${ADMIN_HOME}/Desktop"
  [[ -d "$desktop_dir" ]] || desktop_dir="${ADMIN_HOME}/desktop"
  install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$desktop_dir"
  if [[ -f "$TMPDIR/home/admin/desktop/Photostation.desktop" ]]; then
    install -m 0644 "$TMPDIR/home/admin/desktop/Photostation.desktop" "$desktop_dir/Photostation.desktop"
  fi

  cat > "$WEB_ROOT/index.html" <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=/launcher.html"></head>
<body><p>Redirecting to launcher...</p></body>
</html>
EOF
  chown "$ADMIN_USER:$ADMIN_USER" "$WEB_ROOT/launcher.html" "$WEB_ROOT/index.html"
  chmod 0644 "$WEB_ROOT/launcher.html" "$WEB_ROOT/index.html"
}

apply_permissions() {
  log "Applying runtime ownership and write permissions"

  chown "$ADMIN_USER":www-data "$INSTALL_ROOT"
  chmod 0775 "$INSTALL_ROOT"

  [[ -f "$INSTALL_ROOT/photostation.sh" ]] && chown "$ADMIN_USER:$ADMIN_USER" "$INSTALL_ROOT/photostation.sh" && chmod 0755 "$INSTALL_ROOT/photostation.sh"
  [[ -f "$INSTALL_ROOT/scanner.py" ]] && chown "$ADMIN_USER:$ADMIN_USER" "$INSTALL_ROOT/scanner.py" && chmod 0644 "$INSTALL_ROOT/scanner.py"
  [[ -f "$INSTALL_ROOT/test_capture.sh" ]] && chown root:root "$INSTALL_ROOT/test_capture.sh" && chmod 0755 "$INSTALL_ROOT/test_capture.sh"
  [[ -f "$INSTALL_ROOT/config.conf" ]] && chown www-data:www-data "$INSTALL_ROOT/config.conf" && chmod 0644 "$INSTALL_ROOT/config.conf"

  touch "$INSTALL_ROOT/cookies.txt"
  chown "$ADMIN_USER:$ADMIN_USER" "$INSTALL_ROOT/cookies.txt"
  chmod 0644 "$INSTALL_ROOT/cookies.txt"

  mkdir -p "$INSTALL_ROOT/work" "$INSTALL_ROOT/__pycache__"
  chown -R "$ADMIN_USER:$ADMIN_USER" "$INSTALL_ROOT/work" "$INSTALL_ROOT/__pycache__"
  chmod 0755 "$INSTALL_ROOT/work" "$INSTALL_ROOT/__pycache__"

  chown -R "$ADMIN_USER:$ADMIN_USER" "$PHOTO_WEB_ROOT"
  find "$PHOTO_WEB_ROOT" -type d -exec chmod 0755 {} +
  find "$PHOTO_WEB_ROOT" -type f -exec chmod 0644 {} +
if [ -d "$PHOTO_WEB_ROOT/backup" ]; then
  chmod 0775 "$PHOTO_WEB_ROOT/backup"
fi
  touch \
    "$PHOTO_WEB_ROOT/status.txt" \
    "$PHOTO_WEB_ROOT/hosted_url.txt" \
    "$PHOTO_WEB_ROOT/scout_name.txt" \
    "$PHOTO_WEB_ROOT/pass_flag.txt" \
    "$PHOTO_WEB_ROOT/latest_original.jpg" \
    "$PHOTO_WEB_ROOT/latest_cropped.jpg"

chown "$ADMIN_USER":"$ADMIN_USER" "$PHOTO_WEB_ROOT/status.txt"
chmod 0664 "$PHOTO_WEB_ROOT/status.txt"
# allow Apache to write as well
setfacl -m u:www-data:rw "$PHOTO_WEB_ROOT/status.txt"

  chown "$ADMIN_USER:$ADMIN_USER" \
    "$PHOTO_WEB_ROOT/hosted_url.txt" \
    "$PHOTO_WEB_ROOT/scout_name.txt" \
    "$PHOTO_WEB_ROOT/pass_flag.txt" \
    "$PHOTO_WEB_ROOT/latest_original.jpg" \
    "$PHOTO_WEB_ROOT/latest_cropped.jpg"
  chmod 0644 \
    "$PHOTO_WEB_ROOT/hosted_url.txt" \
    "$PHOTO_WEB_ROOT/scout_name.txt" \
    "$PHOTO_WEB_ROOT/pass_flag.txt" \
    "$PHOTO_WEB_ROOT/latest_original.jpg" \
    "$PHOTO_WEB_ROOT/latest_cropped.jpg"

  echo "READY" > "$PHOTO_WEB_ROOT/status.txt"
  echo "0" > "$PHOTO_WEB_ROOT/pass_flag.txt"
}

install_sudoers() {
  log "Installing sudoers policy for PHP helper actions"
  cat > "$SUDOERS_FILE" <<EOF
www-data ALL=(admin) NOPASSWD: /opt/photostation/test_capture.sh
www-data ALL=(root) NOPASSWD: /bin/systemctl restart photostation.service
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl restart photostation.service
www-data ALL=(root) NOPASSWD: /usr/bin/pkill chromium
EOF
  chmod 0440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" >/dev/null
}

write_kiosk_launchers() {
  log "Writing Chromium kiosk start scripts"
  local browser_cmd
  browser_cmd="$(command -v chromium-browser || command -v chromium || true)"
  [[ -n "$browser_cmd" ]] || fail "Chromium command not found after install"

  install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.config/autostart"

  cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
sleep 5
xset s off >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
pkill -f unclutter >/dev/null 2>&1 || true
(unclutter -idle 0.5 -root >/dev/null 2>&1 &)
if pgrep -f '${browser_cmd}.*launcher.html' >/dev/null 2>&1; then
  exit 0
fi
exec ${browser_cmd} --kiosk --incognito --noerrdialogs --disable-session-crashed-bubble --disable-infobars --password-store=basic http://localhost/launcher.html
EOF
  chmod 0755 "$START_SCRIPT"
  chown "$ADMIN_USER:$ADMIN_USER" "$START_SCRIPT"

  cat > "$DESKTOP_AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Chromium Kiosk
Exec=${START_SCRIPT}
X-GNOME-Autostart-enabled=true
EOF
  chmod 0644 "$DESKTOP_AUTOSTART"
  chown "$ADMIN_USER:$ADMIN_USER" "$DESKTOP_AUTOSTART"
}

start_services() {
  log "Enabling and starting services"
  systemctl daemon-reload
  systemctl enable apache2 >/dev/null
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart apache2
  systemctl restart "$SERVICE_NAME"
}

report_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]   %s\n' "$label"
  else
    printf '  [WARN] %s\n' "$label"
  fi
}

validate_install() {
  log "Validation summary"
  report_check "Apache serving launcher" curl -fsS http://localhost/launcher.html
  report_check "Photostation service active" systemctl is-active --quiet "$SERVICE_NAME"
  report_check "Scanner device visible" bash -lc 'ls /dev/input/by-id/*-event-kbd >/dev/null 2>&1'
  report_check "Camera present (DSLR or webcam)" bash -lc 'gphoto2 --auto-detect 2>/dev/null | grep -q usb: || ls /dev/video* >/dev/null 2>&1'
  report_check "LightDM enabled" systemctl is-enabled lightdm
  report_check "Chromium command installed" bash -lc 'command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1'
  report_check "Audio devices detected" aplay -l

  local base_url
base_url="$(awk -F= '/^BASE_URL=/{print $2}' "$INSTALL_ROOT/config.conf" 2>/dev/null | tail -n1 | tr -d '"'"'" )"
  if [[ -n "$base_url" ]]; then
    if curl --connect-timeout 3 --max-time 5 -fsS -o /dev/null "${base_url%/}/action.php"; then
      printf '  [OK]   DerbyNet endpoint reachable\n'
    else
      printf '  [WARN] DerbyNet endpoint not reachable yet (check network, BASE_URL, or event availability)\n'
    fi
  else
    printf '  [WARN] BASE_URL not set in config.conf\n'
  fi
}

print_finish_message() {
  cat <<EOF

Install complete.

IMPORTANT NEXT STEPS
--------------------
1. Edit: ${INSTALL_ROOT}/config.conf
2. Set the correct DerbyNet BASE_URL for this event/year.
3. Verify DERBYNET_ROLE and DERBYNET_PASSWORD.
4. Reboot the Pi before the event.

Useful commands
---------------
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  cat /etc/lightdm/lightdm.conf.d/99-photostation-autologin.conf
  aplay -l

If you created ${ADMIN_USER} during install and skipped the password prompt,
set one later with:
  sudo passwd ${ADMIN_USER}
EOF
}

main() {
  confirm_wipe
  backup_existing_install
  ensure_admin_user
  install_packages
  extract_package
  wipe_existing_install
  install_app_files
  apply_permissions
  install_sudoers
  configure_lightdm_autologin
  configure_audio
  write_kiosk_launchers
  start_services
  validate_install
  print_finish_message
}

main "$@"
