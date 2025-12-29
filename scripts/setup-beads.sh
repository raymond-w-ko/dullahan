#!/usr/bin/env -S bash -exu

# Only create and push branch if it doesn't exist on origin
if ! git ls-remote --heads origin beads-sync | grep -q beads-sync; then
    git branch beads-sync main
    git push -u origin beads-sync
fi

bd config set sync.branch beads-sync
bd daemons killall
bd ready
