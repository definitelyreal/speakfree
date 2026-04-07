#!/bin/bash
# Usage: ./scripts/dev-loop.sh [test-filter]
# Push code, SSH to VM, pull and run tests.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/vm-env.sh"
VM_PASS=$(cat ~/.openwisprmod-vm-pass)

echo "==> Pushing to git..."
cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
git push

echo "==> Building and testing on Windows VM ($VM_IP)..."
sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no owmadmin@$VM_IP \
  "cd C:\\Users\\owmadmin\\openwisprmod; git pull; dotnet build windows/ --nologo -q; dotnet test windows/ --nologo"

echo "==> Done."
