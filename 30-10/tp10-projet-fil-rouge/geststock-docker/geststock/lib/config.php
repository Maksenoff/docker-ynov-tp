<?php
// Configuration lue dans l'environnement (plus de valeurs en dur), valeurs par defaut pour le dev.

function cfg(string $name, string $default = ''): string {
    $v = getenv($name);
    return ($v === false || $v === '') ? $default : $v;
}

// secret : si NOM_FILE est defini on lit le fichier (docker secret), sinon la variable NOM
function cfg_secret(string $name, string $default = ''): string {
    $file = cfg($name . '_FILE');
    if ($file !== '' && is_readable($file)) {
        return trim((string) file_get_contents($file));
    }
    return cfg($name, $default);
}

define('DB_HOST', cfg('DB_HOST', 'db'));
define('DB_NAME', cfg('DB_NAME', 'geststock'));
define('DB_USER', cfg('DB_USER', 'geststock'));
define('DB_PASS', cfg_secret('DB_PASS'));
define('UPLOAD_DIR', rtrim(cfg('UPLOAD_DIR', '/var/www/uploads'), '/') . '/');
// stderr = logs du conteneur (docker logs, loki)
define('LOG_FILE', cfg('LOG_FILE', 'php://stderr'));
define('SMTP_HOST', cfg('SMTP_HOST', 'localhost'));
define('REPORT_TO', cfg('REPORT_TO', 'direction@shop.example'));
