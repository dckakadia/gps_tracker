#!/usr/bin/env bash
set -euo pipefail
# Usage: ./scripts/push-to-github.sh REPO_NAME [visibility=public|private] [branch=main]
REPO_NAME=${1:-gps_tracker}
VISIBILITY=${2:-public}
BRANCH=${3:-main}

echo "Preparing to push repository as '$REPO_NAME' (visibility: $VISIBILITY) on branch $BRANCH"

if [ ! -d .git ]; then
  echo "Initializing git repository..."
  git init
fi

git add .
git commit -m "Initial commit" || echo "No changes to commit or commit failed"

if command -v gh >/dev/null 2>&1; then
  echo "Creating GitHub repo and pushing using gh..."
  gh repo create "$REPO_NAME" --${VISIBILITY} --source=. --remote=origin --push --public || gh repo create "$REPO_NAME" --${VISIBILITY} --source=. --remote=origin --push
else
  echo "GitHub CLI 'gh' not found. Please install it or create a repo manually."
  echo "Manual steps:"
  echo "  1) Create a repo on github.com"
  echo "  2) git remote add origin <git_url>"
  echo "  3) git push -u origin $BRANCH"
fi

echo "Done."
