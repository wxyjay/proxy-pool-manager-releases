#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_URL="${REMOTE_URL:-git@github.com:wxyjay/proxy-pool-manager-releases.git}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: update release install scripts}"

cd "$ROOT_DIR"

if [[ ! -d .git ]]; then
  git init
  git branch -M main
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$REMOTE_URL"
fi

git config user.name "wxyjay"
git config user.email "wxyjay@users.noreply.github.com"

merge_remote_branch() {
  local branch="$1"
  if git fetch origin "${branch}:refs/remotes/origin/${branch}" >/dev/null 2>&1; then
    if git merge-base --is-ancestor HEAD "origin/${branch}"; then
      git merge --ff-only "origin/${branch}"
    elif git merge-base --is-ancestor "origin/${branch}" HEAD; then
      echo "Local ${branch} already contains origin/${branch}."
    else
      echo "Merging origin/${branch} into local ${branch}..."
      git merge --no-edit "origin/${branch}"
    fi
  else
    echo "Remote ${branch} branch does not exist yet."
  fi
}

git switch main >/dev/null 2>&1 || git switch -c main
git add -A
if ! git diff --cached --quiet; then
  git commit -m "$COMMIT_MESSAGE"
else
  echo "No staged changes to commit."
fi

echo "Syncing main with origin/main..."
merge_remote_branch main

echo "Pushing main..."
git push -u origin main

echo "Merging main into debug..."
if git fetch origin debug:refs/remotes/origin/debug >/dev/null 2>&1; then
  git switch debug >/dev/null 2>&1 || git switch -c debug --track origin/debug
  merge_remote_branch debug
else
  echo "Remote debug branch does not exist; creating it from main."
  git switch debug >/dev/null 2>&1 || git switch -c debug main
fi

git merge --no-edit main
git push -u origin debug
git switch main >/dev/null

echo "Done."
