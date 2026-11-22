#!/bin/bash
# Refresh the Claude Code briefing on the Yoga 9n live stick, then tell you how
# to start the session.
#
#   bash /boot/yoga9n-refresh-briefing.sh
#
# Why this exists: claude-setup.sh copies /boot/yoga9n-CLAUDE.md to
# /root/yoga9n-live/CLAUDE.md as a one-time install step. Claude Code reads the
# copy in /root/yoga9n-live, never the one on /boot. So whenever the Windows
# side updates the briefing on the ESP, the working copy goes stale and the
# session silently runs on old instructions. This re-syncs it. Safe to re-run.
set -euo pipefail
die() { echo "STOP: $*" >&2; exit 1; }

[[ $EUID == 0 ]] || die 'run as root'

root_uuid=$(findmnt -no UUID /)
[[ -f /boot/H7607A-$root_uuid.OK ]] ||
    die 'this is not the live stick (no /boot/H7607A-<root UUID>.OK)'
[[ -f /boot/yoga9n-CLAUDE.md ]] || die '/boot/yoga9n-CLAUDE.md is missing'

workspace=/root/yoga9n-live
install -d -m 700 "$workspace"

if cmp -s /boot/yoga9n-CLAUDE.md "$workspace/CLAUDE.md" 2>/dev/null; then
    echo "Already current: $workspace/CLAUDE.md matches /boot/yoga9n-CLAUDE.md."
else
    if [[ -f $workspace/CLAUDE.md ]]; then
        cp -a "$workspace/CLAUDE.md" "$workspace/CLAUDE.md.stale-$(date +%Y%m%d-%H%M%S)"
        echo "Previous copy kept as $workspace/CLAUDE.md.stale-*"
    fi
    install -m 600 /boot/yoga9n-CLAUDE.md "$workspace/CLAUDE.md"
    echo "Updated $workspace/CLAUDE.md from /boot/yoga9n-CLAUDE.md."
fi

echo
echo "First line of the working copy (expect a READ FIRST banner with a date):"
head -1 "$workspace/CLAUDE.md"
echo

if head -1 "$workspace/CLAUDE.md" | grep -q 'READ FIRST'; then
    echo "Looks right."
else
    echo "WARNING: no READ FIRST banner. The ESP copy may itself be stale;"
    echo "check /boot/yoga9n-notes/ for the newest report before trusting it."
fi

echo
echo "Notes available to the session:"
ls -1 /boot/yoga9n-notes/ 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo
echo "Start the session with:"
echo "  source ~/.bashrc; cd $workspace && claude"
echo
echo "The cd matters: Claude Code finds CLAUDE.md from its working directory"
echo "and that directory's parents, so starting elsewhere loses the briefing."
