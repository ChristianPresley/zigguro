#!/bin/sh
# Regenerates the index fixtures in testdata/index with the system git
# (2.43 was used): one small working tree written as index v2, v3 (an
# intent-to-add entry), v4, a SHA-256 v2 index and a v2 index with a
# merge conflict (stages 1-3). Each directory holds `index` and `ls.txt`,
# the output of `git ls-files --stage` ("<mode> <oid> <stage>\t<path>").
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/index"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$work" GIT_AUTHOR_NAME="A U Thor" GIT_AUTHOR_EMAIL=author@example.com \
    GIT_COMMITTER_NAME="C O Mitter" GIT_COMMITTER_EMAIL=committer@example.com \
    GIT_AUTHOR_DATE="@1700000000 +0100" GIT_COMMITTER_DATE="@1700000000 +0100"

tree() { # $1 = repo
    mkdir -p "$1/src/lib/deep" "$1/docs"
    printf 'hello\n' > "$1/README.md"
    printf 'one\n' > "$1/src/lib/deep/a.zig"
    printf 'two\n' > "$1/src/lib/deep/b.zig"
    printf 'main\n' > "$1/src/main.zig"
    printf '#!/bin/sh\n' > "$1/run.sh"
    chmod +x "$1/run.sh"
    printf 'doc\n' > "$1/docs/guide.md"
    ln -s README.md "$1/link"
}

save() { # $1 = repo, $2 = name
    mkdir -p "$out/$2"
    cp "$1/.git/index" "$out/$2/index"
    git -C "$1" ls-files --stage > "$out/$2/ls.txt"
}

rm -rf "$out"
for v in 2 3 4; do
    r="$work/v$v"
    git init -q "$r"
    tree "$r"
    git -C "$r" add -A
    if [ "$v" = 3 ]; then printf 'new\n' > "$r/later.txt"; git -C "$r" add -N later.txt; fi
    git -C "$r" update-index --index-version "$v"
    save "$r" "v$v"
done

r="$work/sha256"
git init -q --object-format=sha256 "$r"
tree "$r"
git -C "$r" add -A
save "$r" sha256

r="$work/conflict"
git init -q -b main "$r"
printf 'base\n' > "$r/f.txt"
git -C "$r" add f.txt
git -C "$r" commit -qm base
git -C "$r" checkout -qb other
printf 'theirs\n' > "$r/f.txt"
git -C "$r" commit -qam theirs
git -C "$r" checkout -q main
printf 'ours\n' > "$r/f.txt"
git -C "$r" commit -qam ours
git -C "$r" merge -q other >/dev/null 2>&1 || true
save "$r" conflict
