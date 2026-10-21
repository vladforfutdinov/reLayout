#!/bin/bash
# One-time setup of a macOS test VM for scripts/e2e-mac-vm.sh, run inside the VM
# (`ssh -t relayout-mac 'bash -s' < scripts/e2e/vm-setup.sh`; asks for the sudo
# password once). Installs the Command Line Tools without the GUI dialog, keeps
# the session awake, and gives the VM user passwordless sudo — the e2e run writes
# TCC.db and starts the test in the GUI session as root. Test VMs only. SIP must
# be turned off in Recovery separately (`csrutil disable`).
set -euo pipefail
sudo -v
if ! xcode-select -p >/dev/null 2>&1; then
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    # The tools for this macOS major, not the newest: a newer one's SDK can need a
    # newer compiler than it ships with (27.0 on macOS 26.6 did not build).
    major=$(sw_vers -productVersion | cut -d. -f1)
    label=$(softwareupdate -l 2>/dev/null | sed -n "s/^\* Label: \(Command Line Tools for Xcode $major\..*\)\$/\1/p" | sort -V | tail -1)
    [ -n "$label" ] || { echo "no Command Line Tools for macOS $major in softwareupdate -l" >&2; exit 1; }
    echo "installing: $label"
    sudo softwareupdate -i "$label"
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
swiftc --version | head -1
sudo pmset -a displaysleep 0 sleep 0
defaults -currentHost write com.apple.screensaver idleTime 0
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/relayout-e2e >/dev/null
sudo chmod 440 /etc/sudoers.d/relayout-e2e
sudo visudo -cf /etc/sudoers.d/relayout-e2e >/dev/null
csrutil status
echo "VM ready (log in to the GUI, ideally with automatic login)"
