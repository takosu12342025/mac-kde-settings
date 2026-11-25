#!/usr/bin/env bash
set -e

echo "Uninstalling mac-kde-settings..."

pkill -f /usr/local/bin/mac-kde-settings || true
sudo rm -f /usr/local/bin/mac-kde-settings
sudo rm -f /usr/share/applications/mac-kde-settings.desktop

echo "Done! Uninstalled mac-kde-settings"
