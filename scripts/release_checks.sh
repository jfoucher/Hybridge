#!/bin/bash
# Static release-policy checks that are cheap enough to run on every PR.
set -euo pipefail

plutil -lint Sources/PrivacyInfo.xcprivacy Widgets/PrivacyInfo.xcprivacy \
  Sources/Info.plist Widgets/Info.plist

# High-signal credential formats only. Generic words such as token/key produce
# too many documentation false positives and would make this gate ignorable.
if git grep -I -n -E \
  '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16})' \
  -- ':!scripts/release_checks.sh'; then
  echo "Potential committed secret detected" >&2
  exit 1
fi

git diff --check
