<?php
// Sets PHOTO_TYPE in config.conf to car or head (racer headshot)
$type = isset($_GET['type']) ? $_GET['type'] : 'car';
if ($type !== 'car' && $type !== 'head') { $type = 'car'; }

$cfg = '/opt/photostation/config.conf';
if (!file_exists($cfg)) { http_response_code(500); echo "Missing config"; exit; }

$txt = file_get_contents($cfg);
if (preg_match('/^PHOTO_TYPE\s*=.*$/m', $txt)) {
  $txt = preg_replace('/^PHOTO_TYPE\s*=.*$/m', "PHOTO_TYPE=".$type, $txt);
} else {
  $txt .= "\nPHOTO_TYPE=".$type."\n";
}
file_put_contents($cfg, $txt);

// Restart service so script reads new mode (simple + reliable)
exec('sudo systemctl restart photostation.service 2>&1');

echo "OK";
