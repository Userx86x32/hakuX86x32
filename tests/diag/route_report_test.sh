#!/bin/sh
# Host test of tools/diag/route_report.sh alone (no phone, a few seconds):
# the hakuX adapter's summary.csv and report.txt of a batch made up line by
# line (report_fixture.sh) are, byte for byte, what route_report.sh made of
# it before the runner was split into a core and adapters (golden/); runs
# that started from another savestate are kept apart.
#   sh tests/diag/route_report_test.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$ROOT/tests/diag
M=$(mktemp -d)
trap 'rm -rf "$M"; exit $fail' EXIT
fail=0
check() { if eval "$1"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
report() { sh "$ROOT/tools/diag/route_report.sh" "$1" > "$M/out.txt" 2> "$M/err.txt"; }
same_report() { sed "s|$1|BATCH|" "$1/report.txt" | cmp -s "$T/golden/hakux_report.txt" -; }
# a line's inputs= in run.txt (the runner's: the route's and savestate's checksums, short)
inputs() { echo "inputs=$2" >> "$1/run.txt"; }

echo "== the hakuX adapter's report: as before the split (tests/diag/golden)"
sh "$T/report_fixture.sh" "$M/b1"
report "$M/b1"
check 'cmp -s "$T/golden/hakux_summary.csv" "$M/b1/summary.csv"'
check 'same_report "$M/b1"'
check 'grep -q "^06-bower-b: no \"pad script: done\" (cut short)$" "$M/err.txt" && grep -q "^08-bower-b: no \"pad script: started\"" "$M/err.txt"'

echo "== batch.txt naming the adapter, and the same inputs in every run: the same report"
sh "$T/report_fixture.sh" "$M/b2"
printf 'adapter=hakux\npackage=com.rfandango.haku_x.debug\nthreads=vcpu=SDLThread decode=hle-pb render=hle.render main=SDLActivity apu=apu.frame\n' >> "$M/b2/batch.txt"
for r in "$M"/b2/0*; do inputs "$r" "route:aaaa1111 state:bbbb2222"; done
report "$M/b2"
check 'cmp -s "$T/golden/hakux_summary.csv" "$M/b2/summary.csv" && same_report "$M/b2" && [ ! -e "$M/b2/inputs.txt" ]'

echo "== lookout's savestate saved again after its second run: its runs in two groups, bower's in one"
sh "$T/report_fixture.sh" "$M/b3"
for r in 01-lookout-a 02-lookout-b; do inputs "$M/b3/$r" "route:aaaa1111 state:11111111"; done
for r in 03-lookout-a 04-lookout-probe-perfetto; do inputs "$M/b3/$r" "route:aaaa1111 state:22222222"; done
for r in 05-bower-a 06-bower-b 07-bower-a 08-bower-b 09-bower-probe-simpleperf; do inputs "$M/b3/$r" "route:cccc3333 state:44444444"; done
report "$M/b3"
check 'grep -q "^01-lookout-a,lookout#1/a," "$M/b3/summary.csv" && grep -q "^02-lookout-b,lookout#1/b," "$M/b3/summary.csv"'
check 'grep -q "^03-lookout-a,lookout#2/a," "$M/b3/summary.csv" && grep -q "^04-lookout-probe-perfetto,lookout#2/a/probe-perfetto," "$M/b3/summary.csv"'
check 'grep -q "^05-bower-a,bower/a," "$M/b3/summary.csv"'
# the numbers: each run's as before, only the group in its name
check 'sed "s|^\([^,]*\),lookout#[12]/|\1,lookout/|" "$M/b3/summary.csv" | cmp -s "$T/golden/hakux_summary.csv" -'
check 'grep -q "^Inputs changed within the batch" "$M/b3/report.txt" && grep -q "^  lookout#1  *route:aaaa1111 state:11111111 (from 01-lookout-a)$" "$M/b3/report.txt"'
check 'grep -q "^  lookout#2  *route:aaaa1111 state:22222222 (from 03-lookout-a)$" "$M/b3/report.txt" && ! grep -q "^  bower#" "$M/b3/report.txt"'
check 'grep -q "^lookout#1/a  *1 " "$M/b3/report.txt" && grep -q "^lookout#2/a  *1 " "$M/b3/report.txt" && grep -q "^lookout#1/b  *1 " "$M/b3/report.txt"'
check '[ "$(wc -l < "$M/b3/inputs.txt")" = 2 ]'
