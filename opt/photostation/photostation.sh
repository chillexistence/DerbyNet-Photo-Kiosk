#!/usr/bin/env bash
# Photostation v3.1.2
set -euo pipefail

VERSION="v3.1.1"

# #######################################################################
# This was created and designed by Cub Scouts Pack 2, Downingtown, PA USA
# https://github.com/chillexistence/DerbyNet-Photo-Kiosk
# #######################################################################
#sudo apt install fonts-noto-color-emoji  (USED FOR BROWSER AUTO PASS ON/OFF)
#sudo apt install sox  (USED FOR BEEP)
#Change ALSA_CARD=2 to Audio Output Source


CONFIG="/opt/photostation/config.conf"
WORKDIR="/opt/photostation/work"
COOKIES="/opt/photostation/cookies.txt"

WEBROOT="/var/www/html/photostation"
STATUS_FILE="$WEBROOT/status.txt"
HOSTED_URL_FILE="$WEBROOT/hosted_url.txt"
SCOUT_NAME_FILE="$WEBROOT/scout_name.txt"
PASS_FLAG_FILE="$WEBROOT/pass_flag.txt"

FIFO="/tmp/photostation_fifo"

mkdir -p "$WORKDIR"

config_error() {
  local msg="$1"

  echo "$msg" > /var/www/html/photostation/status.txt
  echo "" > /var/www/html/photostation/hosted_url.txt

  logger "$msg"

  # keep service alive so UI can display error
  while true; do
      sleep 60
  done
}

validate_config() {
  # Must look like a real URL
  if [[ ! "$BASE_URL" =~ ^https?://[^/]+/.+ ]]; then
    config_error "CONFIG ERROR: BASE_URL is invalid: $BASE_URL"
  fi
}


source "$CONFIG"

validate_config
: "${BASE_URL:?Missing BASE_URL in config.conf}"
: "${DERBYNET_ROLE:?Missing DERBYNET_ROLE in config.conf}"
: "${DERBYNET_PASSWORD:?Missing DERBYNET_PASSWORD in config.conf}"


status() { echo "$1" > "$STATUS_FILE"; }

clear_success_payload() {
  : > "$HOSTED_URL_FILE" 2>/dev/null || true
  : > "$SCOUT_NAME_FILE" 2>/dev/null || true
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }


# Normalize BASE_URL
BASE_URL="${BASE_URL%/}"        # remove trailing slash

network_check() {
  curl --connect-timeout 3 --max-time 5 -o /dev/null "${BASE_URL%/}/action.php"
}

# fallback if AUDIO_DEVICE not defined
AUDIO_DEVICE="${AUDIO_DEVICE:-default}"

audio_disabled() {
  [ "${AUDIO_DEVICE:-default}" = "none" ]
}

aplay_out() {
  if audio_disabled; then
    cat >/dev/null
    return 0
  fi

  if [ "${AUDIO_DEVICE:-default}" = "default" ]; then
    aplay -q -c 2
  else
    aplay -D "$AUDIO_DEVICE" -q -c 2
  fi
}

play_beep() {
  command -v play >/dev/null 2>&1 || return 0
  audio_disabled && return 0

  play -q -n synth 0.08 sine 1000 vol 0.5 >/dev/null 2>&1 || true
  sleep 0.12
}

say() {
  local text="$*"
  [ -n "$text" ] || return 0
  audio_disabled && return 0
  command -v espeak-ng >/dev/null 2>&1 || return 0

  (
    flock 9
    espeak-ng -v mb-us1 -s 165 -p 65 -a 160 "$text" --stdout \
      | aplay_out
  ) 9>/tmp/tts.lock >/dev/null 2>&1 &
}

say_sync() {
  local text="$*"
  [ -n "$text" ] || return 0
  audio_disabled && return 0

  if command -v espeak-ng >/dev/null 2>&1; then
    flock 9
    espeak-ng -v mb-us1 -s 165 -p 65 -a 160 "$text" --stdout \
      | aplay_out
  else
    sleep 1
  fi
} 9>/tmp/tts.lock

speak_step() {
    local text="$1"
    local start=$(date +%s)

    say_sync "$text"

    local end=$(date +%s)
    local elapsed=$((end - start))

    # ensure each step lasts at least 1 second
    if [ "$elapsed" -lt 1 ]; then
        sleep $((1 - elapsed))
    fi
}



car_phrases=(
  "looks fast!"
  "is ready to fly!"
  "is built for speed!"
  "is a serious racer!"
  "is ready for the track!"
  "looks like a winner!"
)

login() {
  curl --connect-timeout 5 \
       --max-time 15 \
       --retry 1 \
       --retry-delay 2 \
       -sS -c "$COOKIES" -b "$COOKIES" \
       -d "action=role.login" \
       -d "name=$DERBYNET_ROLE" \
       -d "password=$DERBYNET_PASSWORD" \
       "$BASE_URL/action.php"
}

json_outcome_summary() {
  local json_file="$1"
  # If jq can't parse JSON, this will return empty.
  jq -r '.outcome.summary // empty' "$json_file" 2>/dev/null || true
}

sanitize_barcode() {
  local s="$1"

  # Drop CR/LF some scanners send
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"

  # Trim leading/trailing whitespace
  s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  # Remove trailing dot(s): "12345." or "12345..."
  while [[ "$s" == *"." ]]; do
    s="${s%.}"
  done

  printf '%s' "$s"
}

download_logo() {
  # Best-effort: keep last good logo if offline
  curl -sS --max-time 10 -o "$WEBROOT/assets/logo.png" \
    "${BASE_URL%/}/image.php/emblem" || true
}

upload_photo() {
  local barcode="$1"
  local file="$2"
  local repo="$3"

  local tmp_json tmp_err summary
  tmp_json="$(mktemp)" || return 1
  tmp_err="$(mktemp)" || { rm -f "$tmp_json"; return 1; }
  
  
  do_upload() {
    curl -sS -b "$COOKIES" -c "$COOKIES" \
      -F "action=photo.upload" \
      -F "barcode=$barcode" \
      -F "repo=$repo" \
      -F "photo=@$file" \
      "$BASE_URL/action.php" \
      >"$tmp_json" 2>"$tmp_err" || true
  }

  do_upload
	summary="$(jq -r '.outcome.summary // empty' "$tmp_json" 2>/dev/null || true)"
	code="$(jq -r '.outcome.code // empty' "$tmp_json" 2>/dev/null || true)"

	# Retry only if not a barcode error
	if [[ "$summary" != "success" && "$code" != "barcode" ]]; then
	  rm -f "$COOKIES"
	  login >/dev/null 2>&1 || true
	  do_upload
	  summary="$(jq -r '.outcome.summary // empty' "$tmp_json" 2>/dev/null || true)"
	fi


  cat "$tmp_json"
  rm -f "$tmp_json" "$tmp_err"

  [[ "$summary" == "success" ]]
}


racer_get_name() {
  local barcode="$1"

  # Extract digits from PWDid058. -> 058 (works fine as racerid)
  local racerid="${barcode//[^0-9]/}"

  curl --connect-timeout 5 \
       --max-time 15 \
       -sS -c "$COOKIES" -b "$COOKIES" \
       "$BASE_URL/action.php?query=racer.list&racerid=$racerid"
}

capture_photo() {
  local outfile="$1"

  # Try DSLR first
  if gphoto2 --summary >/dev/null 2>&1; then
    gphoto2 --capture-image-and-download \
      --force-overwrite \
      --filename "$outfile"
    return $?
  fi

  # Fallback to webcam
#  if [ -e /dev/video0 ]; then
#    fswebcam -r 1280x720 --no-banner --jpeg 95 "$outfile" || return 1
#    return $?
#  fi
# Fallback to any available webcam
for dev in /dev/video*; do
  [ -e "$dev" ] || continue

  # Try to capture a frame; skip first frames to let camera settle
  if fswebcam -d "$dev" -S 5 -r 1280x720 --no-banner --jpeg 95 "$outfile" >/dev/null 2>&1; then
    return 0
  fi
done

# If no device worked

  return 1
}


apply_crop() {
  local infile="$1"
  local outfile="$2"

  echo "Applying crop to: $infile"
  echo "Saving cropped image to: $outfile"

  # Get the crop percentage from the config file
CROP_PERCENT=$(grep -i 'CROP_PERCENT' "$CONFIG" | cut -d'=' -f2)

# If CROP_PERCENT is missing or empty, set a default value (e.g., 92)
if [ -z "$CROP_PERCENT" ]; then
  echo "Warning: CROP_PERCENT not found in config.conf. Using default value: 92%"
  CROP_PERCENT=92  # Default value
fi

  # Debugging: Print the crop percentage
  echo "Crop percentage: $CROP_PERCENT%"

  # Get the dimensions of the original image (width and height)
  IMAGE_WIDTH=$(identify -format "%w" "$infile")
  IMAGE_HEIGHT=$(identify -format "%h" "$infile")

  # Debugging: Print image dimensions
  echo "Image dimensions: ${IMAGE_WIDTH}x${IMAGE_HEIGHT}"

  # Calculate the crop dimensions
  CROP_WIDTH=$(($IMAGE_WIDTH * $CROP_PERCENT / 100))
  CROP_HEIGHT=$(($IMAGE_HEIGHT * $CROP_PERCENT / 100))
  CROP_X=$((($IMAGE_WIDTH - $CROP_WIDTH) / 2))
  CROP_Y=$((($IMAGE_HEIGHT - $CROP_HEIGHT) / 2))

  # Debugging: Print crop details
  echo "Cropping to: ${CROP_WIDTH}x${CROP_HEIGHT}+${CROP_X}+${CROP_Y}"

  # Apply cropping using ImageMagick
  convert "$infile" -crop ${CROP_WIDTH}x${CROP_HEIGHT}+${CROP_X}+${CROP_Y} "$outfile"

  # Check if the cropped image was created
  if [ ! -f "$outfile" ]; then
    echo "Error: Cropped image not created."
    return 1
  fi

  echo "Cropped image saved to: $outfile"
}


main_loop() {
  busy=0

  while IFS= read -r barcode; do
    # Clean up barcode (removes trailing '.', CR/LF, whitespace)
    barcode="$(sanitize_barcode "$barcode")"
    [[ -z "$barcode" ]] && continue

   # Reload config each scan to get current mode
   source "$CONFIG"
   current_type="${PHOTO_TYPE:-car}" 
   barcode=$(echo "$barcode" | tr -d '\r\n')
    [ -z "$barcode" ] && continue
    [ "$busy" -eq 1 ] && continue
    
    play_beep
    sleep 0.1
    say "Barcode scanned."
    # wait until the speech finishes
    flock /tmp/tts.lock true

    busy=1
    clear_success_payload

    echo "0" > "$PASS_FLAG_FILE"

    status "CAPTURING PHOTO..."
    if [ "$current_type" = "head" ]; then
        prefix="Racer"
    else
        prefix="Car"
    fi

	# #################################################
	# Moved UP so we can use Racer's name in file name
	# Fetch racer info (non-fatal)
	# #################################################
	racer_get_name "$barcode" > /tmp/racer_list.json 2>/dev/null || true

	lookup_code=$(jq -r '.outcome.code // empty' /tmp/racer_list.json 2>/dev/null)

	if [ "$lookup_code" = "notauthorized" ]; then
	  login >/dev/null 2>&1 || true
	  racer_get_name "$barcode" > /tmp/racer_list.json 2>/dev/null || true
	  lookup_code=$(jq -r '.outcome.code // empty' /tmp/racer_list.json 2>/dev/null)

	  if [ "$lookup_code" = "notauthorized" ]; then
		status "LOGIN FAILED"
		say "Login failed. Please see race coordinator."
		busy=0
		continue
	  fi
	fi

	name=""
	carname=""
	safe_name=""
	name_part=""

	IFS="|" read -r name carname <<< "$(jq -r '
	  .racers[0] |
	  "\((.firstname // "") + " " + (.lastname // ""))|\(.carname // "")"
	' /tmp/racer_list.json 2>/dev/null || true)"

	# clean whitespace
	name="$(echo "$name" | xargs 2>/dev/null || true)"
	carname="$(echo "$carname" | xargs 2>/dev/null || true)"
	# Warn if name lookup failed
	if [ -z "$name" ]; then
	  echo "Warning: racer name lookup failed for $barcode" >&2
	else
	  safe_name="$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-30)"
	  name_part="${safe_name}_"
	fi
	# Save scout name for UI
	if [ -n "$name" ]; then
	  echo "$name" > "$SCOUT_NAME_FILE" 2>/dev/null || true
	else
	  : > "$SCOUT_NAME_FILE"
	fi
	# #########################################
	# End Racer Name & Car Name Lookup and Save
	# #########################################

	# Check to see if Failed Login
	lookup_code=$(jq -r '.outcome.code // empty' /tmp/racer_list.json 2>/dev/null)
	
	if [ "$lookup_code" = "notauthorized" ]; then
	  # attempt one re-login and retry lookup
	  login >/dev/null 2>&1 || true
	  racer_get_name "$barcode" > /tmp/racer_list.json 2>/dev/null || true
	  lookup_code=$(jq -r '.outcome.code // empty' /tmp/racer_list.json 2>/dev/null)
	
	  if [ "$lookup_code" = "notauthorized" ]; then
	    status "LOGIN FAILED"
	    say "Login failed. Please see race coordinator."
	    busy=0
	    continue
	  fi
	fi

    #outfile="$WORKDIR/${barcode}.jpg"
    outfile="$WORKDIR/${prefix}_${name_part}${barcode}.jpg"

    if [ "$current_type" = "head" ]; then
        # wait for any previous speech to finish
        flock /tmp/tts.lock true

        # 3 second countdown
	say_sync "Alright racers… get ready."

        status "3..."
        speak_step "Three"
        
        status "2..."
        speak_step "Two"

        status "1..."
        speak_step "One, Smile!"
    fi

    status "CAPTURING PHOTO..."

    if ! capture_photo "$outfile"; then
      status "CAMERA ERROR"
      say "Camera error. Please see a leader."
      busy=0
      continue
    fi

    if [ ! -s "$outfile" ]; then
      status "CAMERA ERROR"
      busy=0
      continue
    fi

#cropped_outfile="$WORKDIR/${prefix}_${barcode}_cropped.jpg"
cropped_outfile="$WORKDIR/${prefix}_${name_part}${barcode}_cropped.jpg"
if ! apply_crop "$outfile" "$cropped_outfile"; then
  status "CROP ERROR"
  busy=0
  continue
fi

status "UPLOADING..."
say "Uploading."
upload_photo "$barcode" "$cropped_outfile" "$current_type" > /tmp/upload.json || true

upload_status=$(jq -r '.outcome.summary // empty' /tmp/upload.json 2>/dev/null)
upload_code=$(jq -r '.outcome.code // empty' /tmp/upload.json 2>/dev/null)

if [ "$upload_status" != "success" ]; then
	if ! network_check; then
	  status "NETWORK DISCONNECTED"
	  say "Network Disconnected. Please check wifi."
	  busy=0
	  continue
	fi
	if [ "$upload_code" = "barcode" ]; then
	  racer_id=$(echo "$barcode" | tr -cd '0-9')
	  status "RACER $racer_id NOT RECOGNIZED"
	  say "Racer $racer_id not recognized. Please rescan."
	elif [ "$upload_code" = "notauthorized" ]; then
	  status "LOGIN FAILED"
	  say "Login failed. Please see race coordinator."
	else
	  status "UPLOAD FAILED"
	  say "Upload failed. Please try again."
	fi

  busy=0
  continue
fi

# Only auto-pass if in Car mode AND feature enabled
pass_success=0
if [ "$current_type" = "car" ] && [ "${AUTO_PASS_ON_UPLOAD:-0}" = "1" ]; then
  # PWDid058. -> 058 -> 58
  racer_id="$(echo "$barcode" | tr -cd '0-9' | sed 's/^0*//')"
  [ -z "$racer_id" ] && racer_id="0"

  if [ "$racer_id" != "0" ]; then
    curl -sS -c "$COOKIES" -b "$COOKIES" \
      -d "action=racer.pass" \
      -d "racer=$racer_id" \
      -d "value=1" \
      "$BASE_URL/action.php" > /tmp/pass_response.json 2>&1 || true


    flock /tmp/tts.lock true
    pass_summary="$(jq -r '.outcome.summary // empty' /tmp/pass_response.json 2>/dev/null)"
    if [ "$pass_summary" = "success" ]; then
      echo "1" > "$PASS_FLAG_FILE"
      pass_success=1
    else
      echo "0" > "$PASS_FLAG_FILE"
    fi
  fi
fi


# Only allow car name in car mode
if [ "$current_type" != "car" ]; then
  carname=""
fi

# Write FULLSIZE hosted URL for UI (preserve version token)
photo_url=$(jq -r '.["photo-url"] // empty' /tmp/upload.json 2>/dev/null)

if [ -n "$photo_url" ]; then
  fullsize=$(echo "$photo_url" | sed 's/200x200/1200x1200/')
  echo "${BASE_URL%/}/${fullsize#/}" > "$HOSTED_URL_FILE"
fi


    status "Done"
    busy=0

    # wait a tiny moment so UI loads the success screen
    sleep 1.5

# Speak Success
#name="$(xargs < "$SCOUT_NAME_FILE" 2>/dev/null || true)"

if [ "$current_type" = "car" ]; then
    if [ "$pass_success" = "1" ]; then
        if [ -n "$name" ]; then
            say "Success... $name, ready to race your best!"
        else
            say "Success... Ready to race your best!"
        fi
    else
        if [ -n "$name" ]; then
            say "Success... Thank you $name. Race your best!"
        else
            say "Success... Thank you. Race your best!"
        fi
    fi
   if [ -n "$carname" ]; then
        phrase="${car_phrases[$RANDOM % ${#car_phrases[@]}]}"
        say "$carname $phrase"
   fi
else
    if [ -n "$name" ]; then
	# wait until speech finishes
	flock /tmp/tts.lock true
        say "Success... Great headshot $name!"
    else
	# wait until speech finishes
	flock /tmp/tts.lock true
        say "Success... Great headshot!"
    fi
fi

# wait for speech to finish before continuing
flock /tmp/tts.lock true

  done
}

boot() {
  status "READY ($VERSION)"
  clear_success_payload
  login >/dev/null 2>&1 || true
  download_logo

  # clear leftover speech from previous run
  pkill -f espeak-ng 2>/dev/null || true
  rm -f /tmp/tts.lock
}

boot

rm -f "$FIFO"
mkfifo "$FIFO"

python3 /opt/photostation/scanner.py > "$FIFO" &

main_loop < "$FIFO"
