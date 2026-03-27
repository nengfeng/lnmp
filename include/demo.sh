#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

DEMO() {
  pushd ${current_dir}/src > /dev/null
  if [ ! -e ${wwwroot_dir}/default/index.html ]; then 
    /bin/cp ${current_dir}/config/index.html ${wwwroot_dir}/default/
  fi

  if [ -e "${php_install_dir}/bin/php" ]; then
    # Server probe (inline, no download needed)
    cat > ${wwwroot_dir}/default/xprober.php << 'PHP'
<?php
/**
 * Server Probe - PHP/MySQL/Redis info
 */
error_reporting(0);
$disabled = explode(',', ini_get('disable_functions'));
if (in_array('php_uname', $disabled)) {
    $sys = 'Unknown';
} else {
    $sys = php_uname();
}
$info = [
    'Server IP' => $_SERVER['SERVER_ADDR'] ?? $_SERVER['LOCAL_ADDR'] ?? 'N/A',
    'Server OS' => $sys,
    'PHP Version' => PHP_VERSION,
    'PHP SAPI' => php_sapi_name(),
    'Memory Limit' => ini_get('memory_limit'),
    'Max Upload' => ini_get('upload_max_filesize'),
    'Max POST' => ini_get('post_max_size'),
    'Max Execution Time' => ini_get('max_execution_time') . 's',
    'MySQL' => extension_loaded('mysqli') ? 'Enabled' : (extension_loaded('pdo_mysql') ? 'PDO Enabled' : 'Disabled'),
    'Redis' => extension_loaded('redis') ? 'Enabled' : 'Disabled',
    'OPcache' => extension_loaded('Zend OPcache') ? 'Enabled' : 'Disabled',
];
header('Content-Type: text/html; charset=utf-8');
echo '<html><head><title>Server Probe</title>';
echo '<style>body{font-family:Arial,sans-serif;margin:40px}table{border-collapse:collapse;width:60%}td,th{border:1px solid #ddd;padding:10px;text-align:left}th{background:#4CAF50;color:white}tr:nth-child(even){background:#f2f2f2}</style>';
echo '</head><body><h2>Server Probe</h2><table>';
echo '<tr><th>项</th><th>值</th></tr>';
foreach ($info as $k => $v) {
    echo '<tr><td>' . htmlspecialchars($k) . '</td><td>' . htmlspecialchars($v) . '</td></tr>';
}
echo '</table><p style="color:#999">Powered by LNMP</p></body></html>';
PHP

    echo "<?php phpinfo() ?>" > ${wwwroot_dir}/default/phpinfo.php

    # OPCache probe (inline)
    cat > ${wwwroot_dir}/default/ocp.php << 'PHP'
<?php
/**
 * OPcache Status
 */
if (!extension_loaded('Zend OPcache')) {
    die('OPcache is not enabled');
}
$status = opcache_get_status(false);
$config = opcache_get_configuration();
header('Content-Type: text/html; charset=utf-8');
echo '<html><head><title>OPcache Status</title>';
echo '<style>body{font-family:Arial,sans-serif;margin:40px}table{border-collapse:collapse;width:80%}td,th{border:1px solid #ddd;padding:8px;text-align:left}th{background:#2196F3;color:white}</style>';
echo '</head><body><h2>OPcache Status</h2>';
if ($status && $status['opcache_enabled']) {
    echo '<table><tr><th>项</th><th>值</th></tr>';
    echo '<tr><td>缓存使用率</td><td>' . round($status['memory_usage']['used_memory'] / $status['memory_usage']['free_memory'] * 100, 1) . '%</td></tr>';
    echo '<tr><td>已缓存脚本</td><td>' . $status['opcache_statistics']['num_cached_scripts'] . '</td></tr>';
    echo '<tr><td>命中率</td><td>' . round($status['opcache_statistics']['opcache_hit_rate'], 2) . '%</td></tr>';
    echo '<tr><td>重启次数</td><td>' . $status['opcache_statistics']['oom_restarts'] . '</td></tr>';
    echo '</table>';
} else {
    echo '<p>OPcache is not active</p>';
}
echo '</body></html>';
PHP
  fi
  # Set secure permissions for demo directory (755 for nginx access)
  chmod 755 ${wwwroot_dir}/default
  chown ${run_user}:${run_group} ${wwwroot_dir}/default
  
  # Ensure proper permissions for subdirectories and files
  find ${wwwroot_dir}/default -type d -exec chmod 755 {} \; 2>/dev/null
  find ${wwwroot_dir}/default -type f -exec chmod 644 {} \; 2>/dev/null
  svc_daemon_reload
  popd > /dev/null
}
