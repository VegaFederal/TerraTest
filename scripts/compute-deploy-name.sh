#!/bin/bash
# Computes a short, deterministic, AWS-safe resource-name prefix.
#
# Usage:
#   compute-deploy-name.sh <repo-name> <branch-name>   # per-branch dev name
#   compute-deploy-name.sh <repo-name> --prod          # fixed prod name
#
# <repo-name> is the GitHub repository name (not config/project-config.json's
# free-text projectName), so the deployment name can never drift from or
# collide with another repo that happens to use a similar project name.
#
# The same inputs always produce the same output, so a deploy step and a
# destroy step running in entirely separate workflow runs can each
# independently compute the identical identifier without looking anything up
# or passing state between them.
set -euo pipefail

REPO_NAME="${1:?repo name required}"
TARGET="${2:?branch name (or --prod) required}"

# 24 characters comfortably fits every naming limit currently in play (the
# tightest is ~64 characters, for Lambda function/IAM role names) with
# plenty of headroom for whatever gets added later — kept conservative
# rather than sized to the exact current limits.
MAX_LEN=24
HASH_LEN=8

sanitize() {
  echo -n "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//'
}

REPO_SLUG=$(sanitize "$REPO_NAME" | cut -c1-8)

if [ "$TARGET" == "--prod" ]; then
  echo "${REPO_SLUG}-prod"
  exit 0
fi

BRANCH_NAME="$TARGET"

# Hash the full, unsanitized, untruncated branch name so two branches that
# only differ after the truncation point can never collide.
HASH=$(printf '%s' "$BRANCH_NAME" | shasum -a 256 | cut -c1-"$HASH_LEN")

BUDGET=$((MAX_LEN - HASH_LEN - 1))          # room for repo + branch + 1 separator
REMAINING=$((BUDGET - ${#REPO_SLUG} - 1))   # room left for branch after repo + its separator
if [ "$REMAINING" -lt 1 ]; then
  REMAINING=1
fi
BRANCH_SLUG=$(sanitize "$BRANCH_NAME" | cut -c1-"$REMAINING" | sed -E 's/-+$//')

if [ -n "$BRANCH_SLUG" ]; then
  echo "${REPO_SLUG}-${BRANCH_SLUG}-${HASH}"
else
  echo "${REPO_SLUG}-${HASH}"
fi
