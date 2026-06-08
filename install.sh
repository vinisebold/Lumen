#!/bin/bash
set -e

# ─── Lumen Installer ───────────────────────────────────────────────────────────
# One-click build and install for macOS (Apple Silicon arm64 / Intel x86_64).
# Installs dependencies, builds from source, configures a LaunchAgent
# background service so no terminal is needed after setup.
# ────────────────────────────────────────────────────────────────────────────────

LUMEN_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/Lumen"
CONFIG_DIR="$HOME/.config/sunshine"
LOG_DIR="$HOME/Library/Logs/Lumen"
BUILD_DIR="$LUMEN_DIR/build"
LAUNCH_AGENT_LABEL="com.lumen.streaming"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
BINARY_PATH="$INSTALL_DIR/sunshine"
PERM_FLAG="$INSTALL_DIR/.permissions_configured"
APP_BUNDLE_SOURCE="$LUMEN_DIR/macos/Lumen.app"
APP_BUNDLE_DEST="$HOME/Applications/Lumen.app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "  ╦   ╦ ╦╔╦╗╔═╗╔╗╔"
echo "  ║   ║ ║║║║║╣ ║║║"
echo "  ╩═╝╚═╝╩ ╩╚═╝╝╚╝"
echo "  Native macOS Game Streaming"
echo ""

# ─── Pre-flight checks ─────────────────────────────────────────────────────────

info "Running pre-flight checks..."

# Check macOS version (need 14+ for CGVirtualDisplay)
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt 14 ]; then
    error "Lumen requires macOS 14 (Sonoma) or later. You have macOS $(sw_vers -productVersion)."
fi
ok "macOS $(sw_vers -productVersion)"

# Check architecture (Apple Silicon arm64 or Intel x86_64)
ARCH=$(uname -m)
case "$ARCH" in
    arm64)
        ok "Apple Silicon ($ARCH)"
        ;;
    x86_64)
        warn "Intel Mac ($ARCH) detected — community-supported. Apple Silicon is recommended."
        ;;
    *)
        error "Unsupported architecture: $ARCH. Only arm64 and x86_64 are supported."
        ;;
esac

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    info "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo "Please complete the Xcode CLT installation, then run this script again."
    exit 1
fi
ok "Xcode Command Line Tools"

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add Homebrew to PATH for this session (paths differ on Apple Silicon vs Intel)
    if [ "$ARCH" = "arm64" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ─── Uninstall previous installation ──────────────────────────────────────────

PREV_FOUND=false
if [ -f "$INSTALL_DIR/sunshine" ] || [ -f "$LAUNCH_AGENT_PLIST" ] || [ -f "$HOME/.local/bin/lumen" ] || [ -d "$HOME/.local/share/lumen" ]; then
    PREV_FOUND=true
fi

if [ "$PREV_FOUND" = true ]; then
    echo ""
    warn "A previous Lumen installation was detected."
    printf "  Do you want to uninstall it before continuing? [y/N] "
    read -r UNINSTALL_ANSWER
    if [ "$UNINSTALL_ANSWER" = "y" ] || [ "$UNINSTALL_ANSWER" = "Y" ]; then
        info "Running uninstall..."
        # Unload LaunchAgent
        if [ -f "$LAUNCH_AGENT_PLIST" ]; then
            launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
            sleep 1
        fi
        # Kill processes
        pkill -x sunshine 2>/dev/null || true
        pkill -x vd_helper 2>/dev/null || true
        sleep 1
        # Remove files
        rm -rf "$INSTALL_DIR" 2>/dev/null || true
        rm -f "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
        rm -f "$HOME/.local/bin/lumen" 2>/dev/null || true
        rm -rf "$HOME/.local/share/lumen" 2>/dev/null || true
        rm -rf "$LOG_DIR" 2>/dev/null || true
        ok "Previous installation removed."
    else
        info "Keeping previous installation (will be overwritten on install step)."
    fi
    echo ""
fi

# ─── Install dependencies ──────────────────────────────────────────────────────

info "Installing build dependencies via Homebrew..."
info "(This may take a few minutes on first run)"

DEPS=(
    cmake           # Build system generator
    boost           # C++ utility libraries (Asio, Log, Process, Locale, etc.)
    pkg-config      # Library path resolution for build system
    openssl@3       # TLS/SSL for HTTPS web UI and RTSP streaming
    opus            # Audio codec for low-latency streaming
    llvm            # Clang/LLVM toolchain (required by Sunshine build)
    doxygen         # Documentation generation (build requirement)
    graphviz        # Documentation graphs (build requirement)
    node            # Web UI build toolchain (Vue 3 + Vite)
    icu4c           # Unicode support (Boost.Locale dependency)
    miniupnpc       # UPnP port mapping for automatic NAT traversal
)

for dep in "${DEPS[@]}"; do
    if brew list "$dep" &>/dev/null; then
        ok "$dep (already installed)"
    else
        info "Installing $dep..."
        brew install "$dep" 2>&1 | tail -1
        ok "$dep"
    fi
done

# ─── Detect SDK path ───────────────────────────────────────────────────────────

info "Detecting macOS SDK..."

SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null)
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    # Try Command Line Tools SDK directly
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    if [ ! -d "$SDK_PATH" ]; then
        error "Could not find macOS SDK. Install Xcode Command Line Tools: xcode-select --install"
    fi
fi

# Verify C++ headers exist in the SDK (this is the key build fix for macOS 15+)
CXX_HEADERS="$SDK_PATH/usr/include/c++/v1"
if [ ! -f "$CXX_HEADERS/__config" ]; then
    # Try a versioned SDK
    LATEST_SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V | tail -1)
    if [ -n "$LATEST_SDK" ] && [ -f "$LATEST_SDK/usr/include/c++/v1/__config" ]; then
        SDK_PATH="$LATEST_SDK"
        CXX_HEADERS="$SDK_PATH/usr/include/c++/v1"
    else
        error "C++ headers not found. Install or update Xcode Command Line Tools: xcode-select --install"
    fi
fi

ok "SDK: $SDK_PATH"
ok "C++ headers: $CXX_HEADERS"

# ─── Build ──────────────────────────────────────────────────────────────────────

info "Building Lumen from source..."

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

OPENSSL_PREFIX=$(brew --prefix openssl@3)
NUM_CORES=$(sysctl -n hw.ncpu)

info "Running cmake configuration..."
cmake -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_WERROR=ON \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
  -DSUNSHINE_ASSETS_DIR="$INSTALL_DIR/assets" \
  -DSUNSHINE_BUILD_HOMEBREW=ON \
  -DSUNSHINE_ENABLE_TRAY=ON \
  -DBOOST_USE_STATIC=OFF \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
  -DCMAKE_CXX_FLAGS="-nostdinc++ -cxx-isystem $CXX_HEADERS -std=gnu++2b -I$OPENSSL_PREFIX/include" \
  -DCMAKE_C_FLAGS="-I$OPENSSL_PREFIX/include" \
  ..

info "Compiling with $NUM_CORES cores (this may take several minutes)..."
make sunshine web-ui vd_helper -j"$NUM_CORES"

ok "Build complete"

# Build get_display_origin helper (used by app launch scripts to find virtual display position)
info "Building display helper tools..."
clang -framework CoreGraphics -o "$BUILD_DIR/get_display_origin" \
  "$LUMEN_DIR/src/platform/macos/get_display_origin.m" 2>/dev/null && \
  ok "get_display_origin" || warn "get_display_origin build failed (non-critical)"

# ─── Install ────────────────────────────────────────────────────────────────────

info "Installing to $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR/scripts"

# Copy binary (follow symlinks)
cp -fL "$BUILD_DIR/sunshine" "$INSTALL_DIR/sunshine" 2>/dev/null || \
  cp -f "$BUILD_DIR/sunshine-"* "$INSTALL_DIR/sunshine" 2>/dev/null

# Copy helper binaries
for helper in vd_helper get_display_origin; do
    if [ -f "$BUILD_DIR/$helper" ]; then
        cp -f "$BUILD_DIR/$helper" "$INSTALL_DIR/$helper"
        ok "Installed $helper"
    fi
done

# Copy assets
ASSETS_SRC=""
if [ -d "$BUILD_DIR/sunshine/assets" ]; then
    ASSETS_SRC="$BUILD_DIR/sunshine/assets"
elif [ -d "$BUILD_DIR/assets" ]; then
    ASSETS_SRC="$BUILD_DIR/assets"
fi

if [ -n "$ASSETS_SRC" ]; then
    rm -rf "$INSTALL_DIR/assets"
    cp -Rf "$ASSETS_SRC" "$INSTALL_DIR/assets"
    ok "Installed assets"
fi

# Ensure web public files (CSS, images, locales) are present.
# Vite's copyPublicDir can fail when outDir is outside the project root.
WEB_PUBLIC="$LUMEN_DIR/src_assets/common/assets/web/public"
if [ -d "$WEB_PUBLIC" ] && [ -d "$INSTALL_DIR/assets/web" ]; then
    cp -Rf "$WEB_PUBLIC"/* "$INSTALL_DIR/assets/web/"
    ok "Installed web assets (CSS, images, locales)"
fi

# Create HID entitlements plist (for gamepad support)
cat > "$INSTALL_DIR/hid_entitlements.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.hid.virtual.device</key>
    <true/>
</dict>
</plist>
PLIST

# Copy example launch scripts
if [ -d "$LUMEN_DIR/scripts" ]; then
    cp -f "$LUMEN_DIR/scripts/"*.sh "$CONFIG_DIR/scripts/" 2>/dev/null
    chmod +x "$CONFIG_DIR/scripts/"*.sh 2>/dev/null
    ok "Installed example launch scripts"
fi

# Clean slate: always write fresh config and apps.json.
# Old configs from previous Sunshine installs can have invalid options
# (e.g. min_bitrate, wrong output_name) that cause confusing warnings.
cat > "$CONFIG_DIR/sunshine.conf" << 'CONF'
# Lumen Configuration
# See https://github.com/trollzem/Lumen for documentation

# Audio: "system" uses ScreenCaptureKit for native system audio capture
# No extra software needed — captures all desktop audio directly.
audio_sink = system

# Maximum streaming bitrate (kbps)
# 80000 (80 Mbps) is good for 4K. Use 40000 for 1080p.
max_bitrate = 80000

# Virtual display: "enabled" creates a display matching client resolution on connect.
# The display is destroyed when the last client disconnects.
# Set to "disabled" to use a physical display or BetterDisplay instead.
virtual_display = enabled

# UPnP: automatic port mapping for remote access through NAT
upnp = enabled

# Encoder: videotoolbox uses Apple Silicon hardware acceleration.
# Falls back to software (libx264) if VT is unavailable.
# encoder = videotoolbox
CONF
ok "Config written to $CONFIG_DIR/sunshine.conf"

cat > "$CONFIG_DIR/apps.json" << 'APPS'
{
  "env": {
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  },
  "apps": [
    {
      "name": "Desktop"
    }
  ]
}
APPS
ok "Created apps.json"

# Always set up Web UI credentials during install.
# Remove any old state file from previous Sunshine installs — paired devices
# won't carry over anyway since Lumen generates its own TLS certificates.
STATE_FILE="$CONFIG_DIR/sunshine_state.json"
rm -f "$STATE_FILE"

echo ""
info "Setting up Web UI credentials..."
echo "  Choose a username and password for the Lumen web interface."
echo "  (You'll use these to log in at https://localhost:47990)"
echo ""
printf "  Username: "
read -r LUMEN_USER
printf "  Password: "
read -rs LUMEN_PASS
echo ""
if [ -n "$LUMEN_USER" ] && [ -n "$LUMEN_PASS" ]; then
    "$INSTALL_DIR/sunshine" --creds "$LUMEN_USER" "$LUMEN_PASS" 2>&1 | grep -v "^$"
    # Verify credentials were actually written
    if [ -f "$STATE_FILE" ] && grep -q "\"username\"" "$STATE_FILE" 2>/dev/null; then
        ok "Web UI credentials saved"
    else
        warn "Failed to save credentials. Set them manually: lumen --creds username password"
    fi
else
    warn "Skipped — you can set credentials later at https://localhost:47990"
fi

# ─── Sign binaries ─────────────────────────────────────────────────────────────

# Check AMFI status
AMFI_STATUS="unknown"
BOOT_ARGS=$(nvram boot-args 2>/dev/null || echo "")
if echo "$BOOT_ARGS" | grep -q "amfi_get_out_of_my_way=1"; then
    AMFI_STATUS="disabled"
else
    AMFI_STATUS="enabled"
fi

# Sign the binary for gamepad support (only if AMFI is disabled).
# With AMFI enabled, restricted entitlements cause macOS to kill the process.
if [ "$AMFI_STATUS" = "disabled" ] && [ -f "$INSTALL_DIR/hid_entitlements.plist" ] && [ -f "$BINARY_PATH" ]; then
    info "Signing binaries for gamepad support..."
    codesign --sign - --entitlements "$INSTALL_DIR/hid_entitlements.plist" --force "$BINARY_PATH" 2>/dev/null
    if [ -f "$INSTALL_DIR/vd_helper" ]; then
        codesign --sign - --force "$INSTALL_DIR/vd_helper" 2>/dev/null
    fi
    ok "Binaries signed with HID entitlements"
fi

# ─── macOS Permissions ─────────────────────────────────────────────────────────

if [ ! -f "$PERM_FLAG" ]; then
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           macOS Permissions Required (one-time setup)            ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║  Add 'sunshine' to Screen Recording and Accessibility:            ║${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║  1. System Settings will open to the correct pane.               ║${NC}"
    echo -e "${YELLOW}║  2. Click the ${GREEN}+${YELLOW} button.                                         ║${NC}"
    echo -e "${YELLOW}║  3. Press ${GREEN}Cmd+Shift+G${YELLOW} and paste the path below:                     ║${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║     ${GREEN}$BINARY_PATH${NC}  ║${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║  4. Check the box next to 'sunshine'.                            ║${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║  Do this for ${GREEN}both${YELLOW} Screen Recording AND Accessibility.                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    info "Opening Screen Recording privacy pane..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null
    echo -n "  Press Enter after granting Screen Recording... "
    read -r

    info "Opening Accessibility privacy pane..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
    echo -n "  Press Enter after granting Accessibility... "
    read -r

    touch "$PERM_FLAG"
    ok "Permissions configured"
fi

# ─── Install LaunchAgent ────────────────────────────────────────────────────────

info "Installing LaunchAgent for background service..."

mkdir -p "$HOME/Library/LaunchAgents"

# Substitute __HOME__ placeholder with actual home directory
sed -e "s|__HOME__|$HOME|g" \
    "$LUMEN_DIR/scripts/com.lumen.streaming.plist" \
    > "$LAUNCH_AGENT_PLIST"

chmod 644 "$LAUNCH_AGENT_PLIST"

# Load the LaunchAgent
if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
    ok "LaunchAgent installed and started"
else
    # Try bootout + bootstrap in case it was already loaded
    launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
    sleep 1
    if launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
        ok "LaunchAgent reinstalled and started"
    else
        warn "Could not start LaunchAgent. You can manually run: launchctl bootstrap gui/\$(id -u) $LAUNCH_AGENT_PLIST"
    fi
fi

# ─── Cleanup old CLI launcher ──────────────────────────────────────────────────

if [ -f "$HOME/.local/bin/lumen" ]; then
    rm -f "$HOME/.local/bin/lumen"
    ok "Removed old CLI launcher (~/.local/bin/lumen)"
fi

if [ -d "$HOME/.local/share/lumen" ]; then
    rm -rf "$HOME/.local/share/lumen"
    ok "Removed old install directory (~/.local/share/lumen)"
fi

# ─── Install .app bundle (Spotlight / Launchpad) ────────────────────────────────

info "Installing Lumen.app..."

mkdir -p "$HOME/Applications"

# Remove previous version if exists
if [ -d "$APP_BUNDLE_DEST" ]; then
    rm -rf "$APP_BUNDLE_DEST"
fi

cp -Rf "$APP_BUNDLE_SOURCE" "$APP_BUNDLE_DEST"
ok "Lumen.app installed to $APP_BUNDLE_DEST"

# ─── Post-install ───────────────────────────────────────────────────────────────

echo ""
echo "  ────────────────────────────────────────────────────"
echo -e "  ${GREEN}Lumen installed successfully!${NC}"
echo "  ────────────────────────────────────────────────────"
echo ""
echo "  Lumen is now running as a background service."
echo "  It will start automatically when you log in."
echo ""
echo "  Web UI: https://localhost:47990"
echo "  Logs:   $LOG_DIR/com.lumen.streaming.log"
echo "  Config: $CONFIG_DIR/sunshine.conf"
echo ""

if [ "$AMFI_STATUS" = "disabled" ]; then
    echo -e "  ${GREEN}Gamepad support: READY${NC}"
    echo "    AMFI is disabled. The binary is signed with HID entitlements."
    echo "    Gamepad will work automatically when you connect from Moonlight."
else
    echo -e "  ${YELLOW}Gamepad support: NOT CONFIGURED${NC}"
    echo "    To enable gamepad/controller support, you need to disable AMFI (one-time):"
    echo ""
    echo "    1. Shut down your Mac completely"
    echo "    2. Hold the power button until 'Loading startup options' appears"
    echo "    3. Select Options > Continue"
    echo "    4. Open Terminal from the Utilities menu"
    echo "    5. Run: nvram boot-args=\"amfi_get_out_of_my_way=1\""
    echo "    6. Restart normally"
    echo ""
    echo "    After this one-time setup, gamepad support works automatically."
    echo "    See README for full details."
fi

echo ""
echo "  Tips:"
echo "    - Search for 'Lumen' in Spotlight to open the Web UI anytime"
echo "    - Or double-click Lumen.app in your Applications folder"
echo ""

# Open the app so it registers in Spotlight/Launchpad index
open "$APP_BUNDLE_DEST" 2>/dev/null || true
echo ""
