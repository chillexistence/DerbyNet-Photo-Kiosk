<?php
$statusFile = '/var/www/html/photostation/status.txt';
$current = trim(@file_get_contents($statusFile));

if (strcasecmp($current, 'Done') === 0) {
    file_put_contents($statusFile, 'READY');
    echo "CLEARED";
} else {
    echo "UNCHANGED";
}
?>