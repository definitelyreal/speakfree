#!/bin/bash
set -euo pipefail

echo "==> Stopping any running instances..."
pkill -f "open-wispr start" 2>/dev/null || true
brew services stop open-wispr 2>/dev/null || true
sleep 1

echo "==> Building from source..."
swift build -c release 2>&1 | tail -1

echo "==> Bundling app..."
bash scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app dev
rm -rf ~/Applications/OpenWispr.app
cp -R OpenWispr.app ~/Applications/OpenWispr.app
rm -rf OpenWispr.app

echo "==> Registering app bundle..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f ~/Applications/OpenWispr.app

echo "==> Resetting permissions (simulates install.sh upgrade)..."
tccutil reset Accessibility com.human37.open-wispr 2>/dev/null || true
tccutil reset Microphone com.human37.open-wispr 2>/dev/null || true

echo ""
echo "==> Launching OpenWispr..."
echo "   You should be prompted for microphone and accessibility permissions."
echo "   The menu bar should show a lock icon while waiting."
echo ""
open ~/Applications/OpenWispr.app --args start
