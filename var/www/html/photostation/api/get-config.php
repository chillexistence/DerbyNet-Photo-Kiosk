<?php
header('Content-Type: application/json');

$cfg = '/opt/photostation/config.conf';

// Default values
$crop = 92;
$photo_type = 'car';
$version = "unknown";


// Check if the config file exists
if (file_exists($cfg)) {
    $txt = file_get_contents($cfg);

    // Extract crop percentage from the config file
    if (preg_match('/CROP_PERCENT\s*=\s*(\d+)/', $txt, $m)) {
        $crop = intval($m[1]);  // Store the crop percentage
    }

    // Extract photo type from the config file
    if (preg_match('/PHOTO_TYPE\s*=\s*([a-zA-Z]+)/', $txt, $m)) {
        $photo_type = trim($m[1]);  // Store the photo type (car or head)
    }


    // Extract AUTO_PASS_ON_UPLOAD (must NOT be commented)
    if (preg_match('/^\s*AUTO_PASS_ON_UPLOAD\s*=\s*(\d+)/m', $txt, $m)) {
        $auto_pass = intval($m[1]);
    }

    // BASE_URL (must NOT be commented)
    if (preg_match('/^\s*BASE_URL\s*=\s*(.+)\s*$/m', $txt, $m)) {
        $base_url = trim($m[1]);
    }

}

// Extract VERSION from photostation.sh
$script = '/opt/photostation/photostation.sh';

if (is_readable($script)) {
    $lines = file($script);
    foreach ($lines as $line) {
        if (strpos($line, 'VERSION=') !== false) {
            $parts = explode('=', $line, 2);
            $version = trim($parts[1], " \t\n\r\"'");
            break;
        }
    }
}


// Return JSON
echo json_encode([
  'base_url'   => $base_url,
  'crop' => $crop,
  'photo_type' => $photo_type,
  'auto_pass' => $auto_pass,
  'version'    => $version
]);
?>
