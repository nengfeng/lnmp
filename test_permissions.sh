#!/bin/bash
# Test script for improved web directory permissions

# Source required files
current_dir=$(dirname "$(readlink -f "$0")")
. ${current_dir}/include/common.sh
. ${current_dir}/options.conf

echo "Testing improved web directory permissions..."
echo "=============================================="

# Create test directories
mkdir -p /tmp/test_wwwroot/default
mkdir -p /tmp/test_wwwlogs

# Test the function
wwwroot_dir="/tmp/test_wwwroot"
wwwlogs_dir="/tmp/test_wwwlogs"

setup_web_directory_permissions

echo ""
echo "Testing directory permissions:"
echo "=============================="

# Check /data directory
if [ -d /data ]; then
  echo "/data permissions: $(stat -c '%a' /data)"
fi

# Check webroot directory
echo "Webroot directory: $(stat -c '%a %U:%G' ${wwwroot_dir})"
echo "Webroot default: $(stat -c '%a %U:%G' ${wwwroot_dir}/default)"

# Check logs directory
echo "Logs directory: $(stat -c '%a %U:%G' ${wwwlogs_dir})"

echo ""
echo "Testing file permissions in webroot:"
echo "===================================="
find ${wwwroot_dir} -type f -exec stat -c '%a %n' {} \;

echo ""
echo "Testing directory permissions in webroot:"
echo "========================================="
find ${wwwroot_dir} -type d -exec stat -c '%a %n' {} \;

# Cleanup test directories
rm -rf /tmp/test_wwwroot /tmp/test_wwwlogs

echo ""
echo "Test completed successfully!"