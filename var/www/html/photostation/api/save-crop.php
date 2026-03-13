<?php
// Get the crop percentage from the GET request, default to 92 if not provided
$crop = isset($_GET['crop']) ? intval($_GET['crop']) : 92;

// Validate crop value
if ($crop < 20) $crop = 20;
if ($crop > 100) $crop = 100;

$cfg = '/opt/photostation/config.conf';

// Check if config file exists
if (!file_exists($cfg)) {
    http_response_code(500);
    echo json_encode(["status" => "error", "message" => "Missing config file"]);
    exit;
}

// Read the content of the config file
$txt = file_get_contents($cfg);

// Check if CROP_PERCENT exists in the file
if (preg_match('/^CROP_PERCENT\s*=.*$/m', $txt)) {
    // If found, replace it with the new crop value
    $txt = preg_replace('/^CROP_PERCENT\s*=.*$/m', "CROP_PERCENT=" . $crop, $txt);
} else {
    // If not found, append the new crop value to the config file
    $txt .= "\nCROP_PERCENT=" . $crop . "\n";
}

// Attempt to write the updated content back to the config file
if (file_put_contents($cfg, $txt) === false) {
    http_response_code(500);
    echo json_encode(["status" => "error", "message" => "Failed to write to config file"]);
    exit;
}

// Immediately update the status.txt to "READY" (Place Your Car screen)
if (file_put_contents('/var/www/html/photostation/status.txt', 'READY') === false) {
    http_response_code(500);
    echo json_encode(["status" => "error", "message" => "Failed to write to status.txt"]);
    exit;
}

// Restart the service
exec('sudo systemctl restart photostation.service 2>&1', $output, $return_var);

// Check if the restart command was successful
if ($return_var !== 0) {
    http_response_code(500);
    echo json_encode(["status" => "error", "message" => "Failed to restart photostation service"]);
    exit;
}

// Return success response
echo json_encode(["status" => "success", "message" => "Crop percentage saved and service restarted"]);
?>
