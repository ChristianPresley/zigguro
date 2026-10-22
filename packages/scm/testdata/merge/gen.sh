#!/bin/sh
# Regenerates the conflict-marker fixtures with git (2.43 was used). Each
# case NN/ has base, ours and theirs, and git merge-file's output in the
# diff3, zdiff3 and merge (default) styles. Tests need only the files.
set -e
cd "$(dirname "$0")"
n=0
case_() {
  n=$((n + 1)); d=$(printf '%02d' $n); mkdir -p "$d"
  printf "$1" > "$d/base"; printf "$2" > "$d/ours"; printf "$3" > "$d/theirs"
  for style in diff3 zdiff3 merge; do
    flag="--$style"; [ "$style" = merge ] && flag=""
    git merge-file -p $flag -L ours -L base -L theirs "$d/ours" "$d/base" "$d/theirs" > "$d/$style" || true
  done
}
case_ 'a\nb\nc\n' 'a\nX\nc\n' 'a\nY\nc\n'
case_ 'a\nb\nc\nd\ne\n' 'a\nB\nX\nc\nd\ne\n' 'a\nB\nY\nc\nd\nE\n'
case_ 'a\nb\nc\nd\ne\nf\n' 'a\nX1\nM\nX2\nf\n' 'a\nY1\nM\nY2\nf\n'
case_ 'a\nb\nc\n' 'a\nP\nX\nS\nc\n' 'a\nP\nY\nS\nc\n'
case_ 'a\nb\nc\n' 'a\nc\n' 'a\nB\nc\n'
case_ 'x\n' 'x\nours\n' 'x\ntheirs\n'
case_ '' 'one\ntwo\n' 'one\nthree\n'
case_ '1\n2\n3\n4\n5\n6\n7\n8\n9\n' '1\nA\n3\n4\n5\n6\n7\nC\n9\n' '1\nB\n3\n4\n5\n6\n7\nD\n9\n'
case_ 'a\nb\nc\n' 'a\nS\nS\nc\n' 'a\nS\nc\n'
case_ 'a\nb\nc\n' 'a\nS\nT\nS\nc\n' 'a\nS\nc\n'
case_ 'head\nmid\ntail\n' 'HEAD\nmid\ntail\n' 'Head\nmid\ntail\n'
case_ 'head\nmid\ntail\n' 'head\nmid\nTAIL\n' 'head\nmid\nTail\n'
case_ 'a\nb\nc\nd\n' 'a\nb1\nb2\nc\nd\n' 'a\nb3\nc\nd\n'
case_ 'k1\nk2\nk3\nk4\nk5\nk6\n' 'k1\nk2\nX\nY\nk5\nk6\n' 'k1\nk2\nY\nX\nk5\nk6\n'
case_ 'fn a() {\n  return 1;\n}\n' 'fn a() {\n  return 2;\n}\n' 'fn a() {\n  return 3;\n}\n'
case_ 'L1\nL2\nL3\n' 'L1\nsame\nL2x\nsame2\nL3\n' 'L1\nsame\nL2y\nsame2\nL3\n'
case_ 'a\nb\n' 'a\nb\nc\nd\n' 'a\nb\nc\ne\n'
case_ 'a\nb\nc\n' 'b\nc\n' 'z\nb\nc\n'
case_ 'one\n' 'two\n' 'three\n'
case_ 'p\nq\nr\ns\nt\n' 'p\nQ\nr\nS\nt\n' 'p\nq2\nr\ns2\nt\n'
