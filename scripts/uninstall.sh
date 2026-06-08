#!/bin/bash
set -e

# ─── Lumen Uninstaller ─────────────────────────────────────────────────────────
# Removes all Lumen files, config, LaunchAgent, and logs.
# ────────────────────────────────────────────────────────────────────────────────

INSTALL_DIR="$HOME/Library/Application Support/Lumen"
CONFIG_DIR="$HOME/.config/sunshine"
LOG_DIR="$HOME/Library/Logs/Lumen"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.lumen.streaming"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"

# Legacy CLI paths (from previous installs)
OLD_INSTALL_DIR="$HOME/.local/share/lumen"
OLD_BIN_DIR="$HOME/.local/bin/lumen"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "  ────────────────────────────────────────────────────"
echo -e "  ${RED}Uninstalling Lumen${NC}"
echo "  ────────────────────────────────────────────────────"
echo ""

# ─── Unload LaunchAgent ────────────────────────────────────────────────────────

if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    info "Stopping Lumen background service..."
    launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
    sleep 1
fi

# ─── Kill any running processes ────────────────────────────────────────────────

if pgrep -x sunshine &>/dev/null; then
    info "Stopping sunshine process..."
    pkill -x sunshine 2>/dev/null || true
    sleep 1
fi

if pgrep -x vd_helper &>/dev/null; then
    pkill -x vd_helper 2>/dev/null || true
fi

# ─── Remove LaunchAgent plist ──────────────────────────────────────────────────

if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    rm -f "$LAUNCH_AGENT_PLIST"
    ok "Removed LaunchAgent plist"
fi

# ─── Remove install directory ──────────────────────────────────────────────────

if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR"
fi

# ─── Remove log directory ──────────────────────────────────────────────────────

if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
    ok "Removed $LOG_DIR"
fi

# ─── Remove config directory ───────────────────────────────────────────────────

if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed $CONFIG_DIR"
fi

# ─── Cleanup legacy CLI paths ──────────────────────────────────────────────────

if [ -d "$OLD_INSTALL_DIR" ]; then
    rm -rf "$OLD_INSTALL_DIR"
    ok "Removed old install directory ($OLD_INSTALL_DIR)"
fi

if [ -f "$OLD_BIN_DIR" ]; then
    rm -f "$OLD_BIN_DIR"
    ok "Removed old CLI launcher ($OLD_BIN_DIR)"
fi

echo ""
echo "  ────────────────────────────────────────────────────"
echo -e "  ${GREEN}Lumen has been fully uninstalled.${NC}"
echo "  ────────────────────────────────────────────────────"
echo ""
