#!/bin/bash
set -euo pipefail

REPO_DIR="/home/$USER/git/anarchy-repo"

# - Change Directory
cd "${REPO_DIR}/x86_64"

# - Remove Existing Database
rm -f anarchy-repo.db anarchy-repo.files anarchy-repo.db.tar.zst anarchy-repo.files.tar.zst

# - Build The Repo Packages
repo-add anarchy-repo.db.tar.zst *.pkg.tar.zst

# - Push The Repo To Github
cd "${REPO_DIR}"
read -rp "Commit message: " msg
git add .
git commit -m "$msg"
git push

echo "##################################"
echo " ANARCHY-REPO SUCCESSFULLY PUSHED "
echo "##################################"
