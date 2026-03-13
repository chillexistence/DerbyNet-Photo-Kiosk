<?php
// Get the crop percentage from the URL
$crop = isset($_GET['crop']) ? (int)$_GET['crop'] : 92;
if ($crop < 20) $crop = 20;
if ($crop > 100) $crop = 100;

// Call the shell script with the crop percentage
shell_exec(sprintf('sudo -u admin /opt/photostation/test_capture.sh %d', $crop));

echo json_encode(["status" => "ok"]);
?>
