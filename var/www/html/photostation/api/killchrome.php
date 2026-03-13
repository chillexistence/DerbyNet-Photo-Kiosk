<?php
// Reset status so UI doesn't replay success
file_put_contents('/var/www/html/photostation/status.txt', 'READY');

exec('sudo /usr/bin/pkill chromium');
echo "OK";
?>
