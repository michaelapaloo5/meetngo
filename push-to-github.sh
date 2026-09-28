#!/usr/bin/env bash
# One command to get this project onto GitHub.
#
#   ./push-to-github.sh
#
# It installs the GitHub CLI if it is missing, asks GitHub to remember you (one
# browser step, only the first time), creates a **private** repository called
# meet-n-go from the branch you are on, and pushes. The last two lines it prints
# are what you do on the other laptop.
#
# Nothing here can be automated past the login: your GitHub credentials are not
# on this machine and this script will not ask you to paste a token into a chat
# or a file. The one interactive step is the browser login GitHub itself opens.

set -euo pipefail

cd "$(dirname "$0")"
REPO_NAME="${REPO_NAME:-meetngo}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "==> working from $(pwd) on branch $BRANCH"

if ! command -v gh >/dev/null 2>&1; then
  echo "==> installing the GitHub CLI (this is the slow part, about 20s)"
  if command -v brew >/dev/null 2>&1; then
    brew install gh
  else
    # Direct .deb, no apt keyring dance: gpg wants a TTY this box does not have,
    # and an unrelated third-party source 404s on apt update.
    arch="$(dpkg --print-architecture)"
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)"
    tag="${tag##*/}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/gh.deb" \
      "https://github.com/cli/cli/releases/download/${tag}/gh_${tag#v}_linux_${arch}.deb"
    sudo dpkg -i "$tmp/gh.deb"
    rm -rf "$tmp"
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  if [ -z "${GH_TOKEN:-}" ]; then
    echo
    echo "==> paste a GitHub personal access token (classic, 'repo' scope only)."
    echo "    make one at https://github.com/settings/tokens -> Generate new token (classic)"
    echo "    tick NOTHING except 'repo'. It is read hidden and stays in this terminal."
    echo "    NEVER paste it into a chat window."
    read -rsp "    token: " GH_TOKEN
    echo
    export GH_TOKEN
  fi
  printf '%s' "$GH_TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token
fi

gh auth setup-git

if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
  echo "==> repository $REPO_NAME already exists, pushing to it"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$(gh api user --jq .login)/$REPO_NAME.git"
else
  echo "==> creating a PRIVATE repository named $REPO_NAME"
  gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
fi

git push -u origin "$BRANCH"

LOGIN="$(gh api user --jq .login)"
URL="https://github.com/$LOGIN/$REPO_NAME"

cat <<EOF

================================================================
  DONE.  Your code is at:

      $URL

  On your other laptop, run this:

      git clone $URL.git
      cd meetngo
      git checkout $BRANCH
      flutter pub get

  Then open $URL/blob/$BRANCH/RUNBOOK.md
  and follow it top to bottom. It is the whole thing:
  Supabase project, database schema, five Edge Functions, one
  seeded driver, and both apps running on a phone.
================================================================
EOF
