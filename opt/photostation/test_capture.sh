#!/usr/bin/env bash

# Capture the crop percentage from the argument passed to the script
CROP_PERCENT="${1:-100}"  # The crop value passed by PHP (e.g., 92 for 92%)

# Ensure a valid crop percentage is passed
if [ -z "$CROP_PERCENT" ]; then
  echo "Error: No crop percentage provided."
  exit 1
fi

# Function to capture an image using DSLR (gphoto2)
capture_dslr_image() {
  # Capture the original image using gphoto2
  echo "Attempting to capture image with DSLR (gphoto2)..."
  gphoto2 --capture-image-and-download --force-overwrite --filename /var/www/html/photostation/latest_original.jpg
}

# Function to capture an image using USB camera (fswebcam)
capture_usb_image() {
  echo "No DSLR found. Falling back to USB camera (fswebcam)..."

  found=0

  for dev in /dev/video*; do
    [ -e "$dev" ] || continue

    if fswebcam -d "$dev" -S 5 -r 1280x720 --no-banner --jpeg 95 \
       /var/www/html/photostation/latest_original.jpg >/dev/null 2>&1; then
        found=1
        break
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo "Error: No USB camera detected."
    exit 1
  fi
}

# Try to capture image with DSLR first
if ! capture_dslr_image; then
  # If DSLR capture fails, fall back to USB camera
  capture_usb_image
fi

# Ensure the original image exists before proceeding
if [ ! -f /var/www/html/photostation/latest_original.jpg ]; then
  echo "Error: The original image was not captured."
  exit 1
fi

# Get the dimensions of the original image (width and height)
IMAGE_WIDTH=$(identify -format "%w" /var/www/html/photostation/latest_original.jpg)
IMAGE_HEIGHT=$(identify -format "%h" /var/www/html/photostation/latest_original.jpg)

# Debug: Print the original image dimensions
echo "Original image size: ${IMAGE_WIDTH}x${IMAGE_HEIGHT}"

# Calculate the crop dimensions based on the percentage to keep
CROP_WIDTH=$(($IMAGE_WIDTH * $CROP_PERCENT / 100))  # Crop width based on percentage to keep
CROP_HEIGHT=$(($IMAGE_HEIGHT * $CROP_PERCENT / 100))  # Crop height based on percentage to keep

# Calculate the starting position (center crop)
CROP_X=$((($IMAGE_WIDTH - $CROP_WIDTH) / 2))  # Start at half the difference from the left
CROP_Y=$((($IMAGE_HEIGHT - $CROP_HEIGHT) / 2))  # Start at half the difference from the top

# Debug: Print the crop dimensions and starting positions for verification
echo "Cropping to ${CROP_WIDTH}x${CROP_HEIGHT} starting from (${CROP_X}, ${CROP_Y})"

# Apply cropping to the original image using the dynamically calculated dimensions and center position
convert /var/www/html/photostation/latest_original.jpg -crop ${CROP_WIDTH}x${CROP_HEIGHT}+${CROP_X}+${CROP_Y} /var/www/html/photostation/latest_cropped.jpg

# Check if the cropped image was created
if [ ! -f /var/www/html/photostation/latest_cropped.jpg ]; then
  echo "Error: The cropped image was not created."
  exit 1
fi

echo "Image cropped successfully to ${CROP_WIDTH}x${CROP_HEIGHT}+${CROP_X}+${CROP_Y}."
