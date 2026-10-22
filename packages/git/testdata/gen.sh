#!/bin/sh
# Regenerates the git fixtures in this directory with the system git
# (2.43 was used). Run from anywhere; output is deterministic except for
# pack ordering details, so commit the result and do not rerun casually.
#
#   sha1/, sha256/      objects/ of a small repository: two packs (with
#                       OFS_DELTA chains, .rev files), a multi-pack-index,
#                       loose objects, a commit-graph, plus listings:
#                       objects.txt  "<oid> <type> <size>" for every object
#                       commits.txt  "<oid> <parents...>" for every commit
#                       refs.txt     `git show-ref` output
#   graph-split/        objects/info of a repository with a 3-layer split
#                       commit-graph chain, an octopus merge and a
#                       generation-v2 overflow (GDO2), plus commits.txt and
#                       gens.txt ("<oid> <topo level> <corrected date>").
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_NOSYSTEM=1 HOME="$work" GIT_AUTHOR_NAME="A U Thor" GIT_AUTHOR_EMAIL=author@example.com \
    GIT_COMMITTER_NAME="C O Mitter" GIT_COMMITTER_EMAIL=committer@example.com
t=1700000000
tick() { t=$((t + 60)); export GIT_AUTHOR_DATE="@$t +0100" GIT_COMMITTER_DATE="@$t +0100"; }

listings() { # $1 = git dir, $2 = out dir
    git --git-dir="$1" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype) %(objectsize)' > "$2/objects.txt"
    git --git-dir="$1" log --all --format='%H %P' | sed 's/ *$//' | sort > "$2/commits.txt"
    git --git-dir="$1" show-ref --head > "$2/refs.txt"
}

make_repo() { # $1 = object format
    fmt=$1; r="$work/$fmt"; out="$here/$fmt"
    git init -q -b main --object-format="$fmt" "$r"
    cd "$r"
    git config pack.writeReverseIndex true
    i=0
    while [ $i -lt 30 ]; do
        tick
        mkdir -p src/sub
        # A file that grows a little each commit makes long delta chains.
        seq 1 $((2000 + i * 7)) > src/big.txt
        { seq 1 500; echo "edit $i"; seq 501 1000; } > src/mid.txt
        seq 1 2000 > src/stable.txt
        echo "rev $i" >> src/sub/log.txt
        printf '#!/bin/sh\necho %s\n' $i > run.sh; chmod +x run.sh
        [ $i -eq 3 ] && ln -s src/big.txt link
        git add -A; git commit -q -m "commit $i"
        i=$((i + 1))
    done
    tick; git tag -a v1 -m "release v1"
    # A commit with encoding, a fake gpgsig and an unknown header, written raw.
    tree=$(git rev-parse HEAD^{tree}); head=$(git rev-parse HEAD)
    printf 'tree %s\nparent %s\nauthor A U Thor <author@example.com> %s +0100\ncommitter C O Mitter <committer@example.com> %s +0100\nencoding ISO-8859-1\nchange-id kxyzzy\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEz\n -----END PGP SIGNATURE-----\n\nsigned-looking commit\n' \
        "$tree" "$head" $t $t > "$work/raw"
    raw=$(git hash-object -t commit -w "$work/raw")
    git update-ref refs/heads/raw "$raw"
    git repack -adf -q --depth=50 --window=50
    i=0
    while [ $i -lt 5 ]; do
        tick; echo "second pack $i" >> src/sub/log.txt; git commit -qam "pack two $i"; i=$((i + 1))
    done
    git repack -d -q
    git multi-pack-index write
    git commit-graph write --reachable
    tick; echo loose > loose.txt; git add loose.txt; git commit -qm "loose commit"
    git pack-refs --all
    tick; git branch side HEAD~2
    rm -rf "$out"; mkdir -p "$out"
    cp -r .git/objects "$out/objects"
    rm -rf "$out/objects/info/packs"
    listings "$r/.git" "$out"
    cd "$here"
}

make_graph() {
    r="$work/graph"; out="$here/graph-split"
    git init -q -b main "$r"; cd "$r"
    tick; echo base > f; git add f; git commit -qm base
    git commit-graph write --reachable --split=no-merge
    for b in a b c; do git checkout -q -b $b main; tick; echo $b > $b; git add $b; git commit -qm $b; done
    git checkout -q main; tick
    git merge -q --no-ff -m octopus a b c
    git commit-graph write --reachable --split=no-merge
    # Generation v2 overflow: a far-future parent followed by an old child.
    export GIT_COMMITTER_DATE="@4000000000 +0000" GIT_AUTHOR_DATE="@4000000000 +0000"
    echo future > f; git commit -qam future
    export GIT_COMMITTER_DATE="@100000000 +0000" GIT_AUTHOR_DATE="@100000000 +0000"
    echo past > f; git commit -qam past
    git commit-graph write --reachable --split=no-merge
    rm -rf "$out"; mkdir -p "$out"
    cp -r .git/objects "$out/objects"
    rm -rf "$out/objects/info/packs"
    git log --all --format='%H %P' | sed 's/ *$//' | sort > "$out/commits.txt"
    cd "$here"
}

make_repo sha1
make_repo sha256
make_graph
