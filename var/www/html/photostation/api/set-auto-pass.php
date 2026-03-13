<?php
header('Content-Type: application/json');

$cfg = '/opt/photostation/config.conf';
$tmp = '/opt/photostation/config.conf.tmp';

// Validate input strictly
$value = $_GET['value'] ?? null;

if ($value !== '0' && $value !== '1') {
    http_response_code(400);
    echo json_encode([
        "status" => "error",
        "message" => "Invalid value"
    ]);
    exit;
}

// Ensure config exists
if (!file_exists($cfg)) {
    http_response_code(500);
    echo json_encode([
        "status" => "error",
        "message" => "Config file missing"
    ]);
    exit;
}

// Read existing config
$lines = file($cfg, FILE_IGNORE_NEW_LINES);
$newLines = [];
$found = false;

foreach ($lines as $line) {

    // Replace existing AUTO_PASS_ON_UPLOAD line
    if (preg_match('/^\s*AUTO_PASS_ON_UPLOAD\s*=/', $line)) {
        $newLines[] = "AUTO_PASS_ON_UPLOAD=$value";
        $found = true;
    } else {
        $newLines[] = $line;
    }
}

// If not found, append it
if (!$found) {
    $newLines[] = "AUTO_PASS_ON_UPLOAD=$value";
}

// Atomic write (prevents partial file corruption)
if (file_put_contents($tmp, implode("\n", $newLines) . "\n") === false) {
    http_response_code(500);
    echo json_encode([
        "status" => "error",
        "message" => "Write failed"
    ]);
    exit;
}

rename($tmp, $cfg);

echo json_encode([
    "status" => "ok",
    "auto_pass" => intval($value)
]);
?>
