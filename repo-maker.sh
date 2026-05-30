#!/bin/bash

# - Change Directory
cd /home/$USER/git/repo/x86_64

# - Remove Existing Database
#
rm repo.db
rm repo.files

# - Build The Repo Packages
#
repo-add repo.db.tar.zst *.pkg.tar.zst

# - Remove Symlinks 
#
rm repo.db 
rm repo.files

# - Rename Database files
#
mv repo.db.tar.zst repo.db 
mv repo.files.tar.zst repo.files

# - Push The Repo To Github
#
cd /home/$USER/git/repo/
read -rp "Commit message: " msg
git add .
git commit -m "$msg"
git push

echo "##################################"
echo " ANARCHY-REPO SUCCESSFULLY PUSHED "
echo "##################################"
