#!/bin/sh
# Real Alpine Git, not Gitling's command dispatcher. Only disposable fixtures.
set -eu
cd /shared/small
git status --porcelain
git log --all --format='%H %an %s'
git show HEAD:README.md | grep initial
printf 'guest edit\n' >> README.md
git diff --exit-code && exit 90 || test "$?" = 1
git add README.md
git diff --cached --exit-code && exit 91 || test "$?" = 1
git commit -m 'guest commit'
git branch topic
git checkout topic
printf topic > topic.txt
git add topic.txt
git commit -m topic
git tag -a prototype-tag -m 'Annotated tag'
git checkout master
git merge --no-ff topic -m merge
printf stash >> README.md
git stash push -m prototype
git stash pop
git restore README.md
git checkout -b replay HEAD~1
git cherry-pick topic
git rebase master
git checkout master
git blame README.md
mkdir -p '中文 目录'
printf unicode > '中文 目录/有 空格.txt'
ln -s README.md relative-link
git add .
git commit -m 'unicode and symlink'
git show HEAD:'中文 目录/有 空格.txt' | grep unicode
git init --bare /shared/remote.git
git remote add offline /shared/remote.git
git push offline master --tags
git clone --no-hardlinks /shared/remote.git /shared/clone
git -C /shared/clone fetch offline 2>/dev/null && exit 92 || true
git -C /shared/clone fetch origin
git fsck --full
test -z "$(git status --porcelain)"
echo WORKFLOWS_OK
