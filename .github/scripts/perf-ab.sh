#!/usr/bin/env bash
# Runs the base and head builds' benchmarks interleaved for the perf gate
# (E14.F06.S02.T02): each round runs base, then head, so drift on the
# runner hits both sides alike.
#
#   perf-ab.sh BASE_TREE HEAD_TREE OUT_DIR [ROUNDS] [SCENARIO_ROUNDS]
#
# Both trees must have run `zig build -Doptimize=ReleaseFast bench-build`.
# Micro benches: the packages with gated budgets (`perfgate list-gated`,
# block and warn), ROUNDS times (default 5). Scenarios: editing_100k,
# view_switch, fuzzy_find_1m and idle in quick mode, SCENARIO_ROUNDS times
# (default 3; PERF_SCENARIOS overrides the list, empty for none), plus 5
# headless startup launches per round. PERF_QUICK=1 passes --quick to the
# bench binaries (for trying the script locally). Runs under Git Bash on
# Windows.
# Results land in
# OUT_DIR/{base,head}/ and are merged into OUT_DIR/{base,head}.json with
# head's perfgate.
set -euo pipefail

base=$1
head=$2
out=$3
rounds=${4:-5}
scenario_rounds=${5:-3}
read -r -a scenarios <<< "${PERF_SCENARIOS-editing_100k view_switch fuzzy_find_1m idle}"
exe=""
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=".exe" ;; esac

perfgate="$head/zig-out/bench-bin/perfgate$exe"
mkdir -p "$out/base" "$out/head"
"$perfgate" env | tee "$out/env.txt"

# Packages with block or warn bench budgets (startup has its own harness).
mapfile -t packages < <("$perfgate" list-gated | awk -F'\t' '$1 != "track" { split($3, a, "/"); print a[1] }' | grep -v '^startup$' | sort -u)
echo "gated packages: ${packages[*]}"

run_side() { # side tree round
	local side=$1 tree=$2 i=$3
	for p in "${packages[@]}"; do
		local bin="$tree/zig-out/bench-bin/$p-bench$exe"
		if [[ -x "$bin" ]]; then
			"$bin" --package "$p" ${PERF_QUICK:+--quick} --out "$out/$side/$p-$i.json" > /dev/null
		else
			echo "$side: no bench binary for $p" >&2
		fi
	done
}

run_scenarios() { # side tree round
	local side=$1 tree=$2 i=$3
	for s in "${scenarios[@]+"${scenarios[@]}"}"; do
		ZG_MACHINE_CLASS=${ZG_MACHINE_CLASS:-} "$tree/zig-out/bin/zigguro$exe" "--bench-scenario=$s" --bench-quick "--bench-out=$out/$side/scenario-$s-$i.json" > "$out/$side/scenario-$s-$i.log" 2>&1 ||
			echo "$side: scenario $s failed (round $i), see scenario-$s-$i.log" >&2
	done
	"$tree/zig-out/bin/zigguro-bench-startup$exe" --exe "$tree/zig-out/bin/zigguro$exe" --runs 5 --cold-runs 0 --platform headless --out "$out/$side/startup-$i.json" > /dev/null ||
		echo "$side: startup bench failed (round $i)" >&2
}

for i in $(seq 1 "$rounds"); do
	echo "micro benches, round $i/$rounds"
	run_side base "$base" "$i"
	run_side head "$head" "$i"
done
for i in $(seq 1 "$scenario_rounds"); do
	echo "scenarios, round $i/$scenario_rounds"
	run_scenarios base "$base" "$i"
	run_scenarios head "$head" "$i"
done

shopt -s nullglob
for side in base head; do
	files=("$out/$side"/*.json)
	"$perfgate" merge --out "$out/$side.json" "${files[@]}"
done
