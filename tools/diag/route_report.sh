#!/system/bin/sh
# Route batch report, the core: what each run of a scene did, and the
# variants (switch settings) side by side. The run's own numbers (an
# emulator's stutters, its window) and the report's extra sections come
# from the batch's adapter (batch.txt adapter=, adapters/<name>.sh beside
# this script; hakux for batches older than the split). Plain sh + POSIX
# awk: runs on the phone (route.sh calls it after a batch) or on any PC with
# sh and awk.
#   sh route_report.sh <batch dir>     writes summary.csv and report.txt there
# A batch dir holds one dir per run (logcat.txt, sensors.csv, run.txt, ...).
B=${1:?usage: sh route_report.sh <batch dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SUM=$B/summary.csv
bt() { sed -n "s/^$1=//p" "$B/batch.txt" 2>/dev/null | tail -n 1; }
ADAPTER=$(bt adapter); ADAPTER=${ADAPTER:-hakux}
APP_PKG=$(bt package)                   # (the generic adapter's app)
[ -f "$HERE/adapters/$ADAPTER.sh" ] || { echo "no adapter $ADAPTER ($HERE/adapters/$ADAPTER.sh)" >&2; exit 1; }
# the adapter's report hooks, when it doesn't define them (README.md)
ad_report_begin() { :; }
ad_report_run() { :; }
ad_report_pin() { :; }
ad_report_extra() { :; }
. "$HERE/adapters/$ADAPTER.sh"
t=$(bt threads); [ -n "$t" ] && THREADS=$t      # the batch's threads (route.cfg may set them)
: "${SF_TIMESTATS_LAYER=SurfaceView[$PKG}"
: "${SF_LAYER_ANY=}"
: "${SF_LABEL=the app's layer}"
: "${REPORT_TITLE=route report}"
: "${WINDOW_WORD=window}"
: "${THREADS=main=@main}"
: "${PERRUN_AWK=}"
: "${MAIN_NOTE=}"
# the thread columns: <key>_run_ms,<key>_wait_ms per THREADS entry (key=name)
TCOLS=$(for kt in $THREADS; do printf ',%s_run_ms,%s_wait_ms' "${kt%%=*}" "${kt%%=*}"; done)
: "${SUMMARY_COLUMNS=run,variant,kind,secs,frames,fps,stutters,per_min,worst_ms,start_gpuss_C,max_gpuss_C,max_batt_C,min_cap_big_khz,min_cap_prime_khz,cpu7_avg_khz,gpu_avg_mhz$TCOLS,sf_frames,sf_gaps,sf_worst_gap_ms,sf_median_ms,sf_source}"
: "${REPORT_SECTIONS=main threads display failed probes perrun}"
echo "$SUMMARY_COLUMNS" > "$SUM"
: > "$B/failed.txt"
ad_report_begin

# awk with summary.csv's columns by name: c("fps") (NA: no such column);
# the header line skipped
COLS='function c(k) { return (k in C) ? $(C[k]) : "NA" }
NR == 1 { for (i = 1; i <= NF; i++) C[$i] = i; next }
'

# Runs that started from other inputs (run.txt inputs=: the savestate's,
# the route's checksums) than the scene's first run are kept apart: their
# scene is <scene>#2, #3... for the whole report (inputs.txt: which is which).
: > "$B/.groups"
for R in "$B"/*/; do
  R=${R%/}
  in=$(sed -n 's/^inputs=//p' "$R/run.txt" 2>/dev/null)
  sc=$(sed -n 's/^scene=//p' "$R/run.txt" 2>/dev/null)
  [ -n "$in" ] && [ -n "$sc" ] && printf '%s\t%s\t%s\n' "${R##*/}" "$sc" "$in" >> "$B/.groups"
done
awk -F'\t' '{ k = $2 SUBSEP $3; if (!(k in g)) { g[k] = ++ng[$2]; first[k] = $1 } r[NR] = $1; s[NR] = $2; key[NR] = k }
  END { for (i = 1; i <= NR; i++) if (ng[s[i]] > 1) print r[i] "\t" s[i] "#" g[key[i]] "\t" s[i] "\t" g[key[i]] }' "$B/.groups" > "$B/.regroup"
if [ -s "$B/.regroup" ]; then
  awk -F'\t' 'FILENAME == ARGV[1] { gs[$1] = $2; next } ($1 in gs) && !(gs[$1] in shown) { shown[gs[$1]] = 1; print gs[$1] "\t" $3 "\tfrom " $1 }' \
    "$B/.regroup" "$B/.groups" > "$B/inputs.txt"
else
  rm -f "$B/inputs.txt"
fi

# name=value lines (file $1) as a summary.csv row (missing: NA)
row() {
  awk -v cols="$SUMMARY_COLUMNS" '{ i = index($0, "="); if (i) { k = substr($0, 1, i - 1); if (!(k in v)) v[k] = substr($0, i + 1) } }
    END { n = split(cols, cs, ","); out = ""
      for (j = 1; j <= n; j++) out = out (j > 1 ? "," : "") ((cs[j] in v) && v[cs[j]] != "" ? v[cs[j]] : "NA")
      print out }' "$1"
}
# ",a,b,c" as name=value lines, by the names in $1
csv_kv() { echo "$2" | awk -F, -v names="$1" '{ n = split(names, k, " "); for (i = 1; i <= n; i++) print k[i] "=" $(i + 1) }'; }
secs_of() { echo "$1" | awk -F: '{ print $1 * 3600 + $2 * 60 + $3 }'; }

for R in "$B"/*/; do
  R=${R%/}
  [ -f "$R/logcat.txt" ] || continue
  run=${R##*/}
  variant=$(sed -n 's/^variant=//p' "$R/run.txt" 2>/dev/null)
  kind=$(sed -n 's/^kind=//p' "$R/run.txt" 2>/dev/null); kind=${kind:-measure}
  # a run that failed its check (the wrong mods, say): kept out of everything
  failed=$(sed -n 's/^failed=//p' "$R/run.txt" 2>/dev/null)
  if [ -n "$failed" ]; then
    printf '%s\t%s\n' "${R##*/}" "$failed" >> "$B/failed.txt"
    continue
  fi
  scene=$(sed -n 's/^scene=//p' "$R/run.txt" 2>/dev/null)
  g=$(awk -F'\t' -v r="$run" '$1 == r { print $2 }' "$B/.regroup"); [ -n "$g" ] && scene=$g
  variant=${variant:-default}
  [ -n "$scene" ] && variant=$scene/$variant          # compared within a scene
  [ "$kind" = measure ] || variant=$variant/probe-$kind
  start_c=$(sed -n 's/^start_gpuss_C=//p' "$R/run.txt" 2>/dev/null)
  V=$R/.vals
  { echo "run=$run"; echo "variant=$variant"; echo "kind=$kind"; echo "start_gpuss_C=${start_c:-NA}"; } > "$V"
  # the run's window (window=<start s> <end s> <pid>) and its own numbers:
  # the adapter's, from its log; else the window run.txt gives
  # (window_start=, window_end= HH:MM:SS, pid=)
  ad_report_run "$R" "$run" "$variant" "$kind" >> "$V" || { rm -f "$V"; continue; }
  win=$(sed -n 's/^window=//p' "$V")
  if [ -z "$win" ]; then
    ws=$(sed -n 's/^window_start=//p' "$R/run.txt"); we=$(sed -n 's/^window_end=//p' "$R/run.txt")
    if [ -z "$ws" ] || [ -z "$we" ]; then
      echo "$run: no measurement window in run.txt (the run didn't start)" >&2; rm -f "$V"; continue
    fi
    win="$(secs_of "$ws") $(secs_of "$we") $(sed -n 's/^pid=//p' "$R/run.txt")"
  fi
  set -- $win; w0=$1 w1=$2 spid=$3
  # clocks, caps and temperatures inside the window (sensors.csv)
  if [ -f "$R/sensors.csv" ]; then
    awk -F, -v t0="$w0" -v t1="$w1" '
      function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
      function num(x) { return x != "NA" && x != "" }
      BEGIN { capb = capp = "" }
      NR == 1 { next }
      { t = secs($1); if (t < t0 - 5 || t > t1 + 5) next
        if (num($9) && $9 / 1000 > gpuss) gpuss = $9 / 1000
        if (num($10) && $10 / 10 > batt) batt = $10 / 10
        if (num($14) && (capb == "" || $14 < capb)) capb = $14
        if (num($15) && (capp == "" || $15 < capp)) capp = $15
        if (num($8)) { c7 += $8; n7++ }
        if (num($2)) { g += $2; ng++ } }
      END {
        printf "max_gpuss_C=%.1f\nmax_batt_C=%.1f\n", gpuss, batt
        print "min_cap_big_khz=" (capb == "" ? "NA" : capb); print "min_cap_prime_khz=" (capp == "" ? "NA" : capp)
        print "cpu7_avg_khz=" (n7 ? sprintf("%.0f", c7 / n7) : "NA"); print "gpu_avg_mhz=" (ng ? sprintf("%.0f", g / ng) : "NA")
      }' "$R/sensors.csv" >> "$V"
  else
    printf 'max_gpuss_C=0.0\nmax_batt_C=0.0\n' >> "$V"
  fi
  # each thread's time on a CPU and waiting for one (run-queue wait) during
  # the window, from its schedstat at the window's start and end (lines:
  # tid run_ns wait_ns slices last_cpu name), by thread name (THREADS:
  # column=name; @main: the process's main thread); a name held by several
  # threads: the busiest, but for one the adapter pins by tid (hakuX: the
  # vCPU's). A thread started after the first snapshot counts from 0.
  pin=$(ad_report_pin "$R" "$spid")
  if [ -s "$R/schedstat_start.txt" ] && [ -s "$R/schedstat_end.txt" ]; then
    awk -v threads="$THREADS" -v pin="$pin" -v spid="$spid" '
      function name(  i, n) { n = $6; for (i = 7; i <= NF; i++) n = n " " $i; return n }
      FNR == NR { r0[$1] = $2; w0[$1] = $3; next }
      $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
        n = name(); dr = $2 - r0[$1]; dw = $3 - w0[$1]
        if (dr < 0 || dw < 0) next           # another thread with a reused tid
        if ($1 == ptid && n == pname) { vr = dr; vw = dw; vset = 1 }
        if ($1 == spid) { br["@main"] = dr; bw["@main"] = dw }
        if (!(n in br) || dr > br[n]) { br[n] = dr; bw[n] = dw }
      }
      BEGIN { split(pin, pp, " "); ptid = pp[1]; pname = pp[2] }
      END {
        if (vset) { br[pname] = vr; bw[pname] = vw }
        nt = split(threads, ts, " ")
        for (i = 1; i <= nt; i++) { k = ts[i]; sub(/=.*/, "", k); n = ts[i]; sub(/^[^=]*=/, "", n)
          if (n in br) printf "%s_run_ms=%.0f\n%s_wait_ms=%.0f\n", k, br[n] / 1e6, k, bw[n] / 1e6 }
      }' "$R/schedstat_start.txt" "$R/schedstat_end.txt" >> "$V"
  fi
  # what the display presented: SurfaceFlinger's actual present times of
  # the app's layer (sflatency.txt: a block of its last 127 frames every 2 s,
  # under "## HH:MM:SS <layer>"). Present times are the monotonic clock: a
  # block's newest frame against its wall time gives the offset that puts
  # them in the window. Frames counted once; gaps only between neighbours
  # in the same block (two blocks may not meet). Gaps: over 1.5 times the
  # median frame interval (16.7 ms at 60 fps, 25 at 40).
  sf=
  if [ -s "$R/sflatency.txt" ]; then
    sf=$(awk -v t0="$w0" -v t1="$w1" '
      function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
      function flush(  i, j, x) {
        if (nb == 0) return
        for (i = 2; i <= nb; i++) { x = b[i]; for (j = i - 1; j >= 1 && b[j] > x; j--) b[j + 1] = b[j]; b[j + 1] = x }
        off[++no] = bw + 0.5 - b[nb] / 1e9
        for (i = 1; i <= nb; i++) { if (!(b[i] in seen)) { seen[b[i]] = 1; fr[++nf] = b[i] }
          if (i > 1 && !((b[i - 1] SUBSEP b[i]) in pair)) { pair[b[i - 1], b[i]] = 1; pa[++np] = b[i - 1]; pb[np] = b[i] } }
        nb = 0
      }
      /^## / { flush(); bw = secs($2); next }
      NF == 3 && $2 > 0 && $2 < 9e18 { b[++nb] = $2 }
      END {
        flush()
        if (!nf) { print ",NA,NA,NA,NA,NA"; exit }
        # the offset: the median of the blocks (a block of an idle layer is old)
        for (i = 2; i <= no; i++) { x = off[i]; for (j = i - 1; j >= 1 && off[j] > x; j--) off[j + 1] = off[j]; off[j + 1] = x }
        o = off[int((no + 1) / 2)]
        if (t1 < t0) t1 += 86400
        for (i = 1; i <= nf; i++) { t = fr[i] / 1e9 + o; if (t >= t0 && t <= t1) n++ }
        for (i = 1; i <= np; i++) { t = pa[i] / 1e9 + o; if (t < t0 || pb[i] / 1e9 + o > t1) continue
          d[++nd] = (pb[i] - pa[i]) / 1e6 }
        if (!n || !nd) { print ",NA,NA,NA,NA,NA"; exit }
        for (i = 2; i <= nd; i++) { x = d[i]; for (j = i - 1; j >= 1 && d[j] > x; j--) d[j + 1] = d[j]; d[j + 1] = x }
        med = d[int((nd + 1) / 2)]
        for (i = 1; i <= nd; i++) if (d[i] > 1.5 * med) g++
        printf ",%d,%d,%.1f,%.1f,latency\n", n, g, d[nd], med
      }' "$R/sflatency.txt")
  fi
  # else SurfaceFlinger's own statistics of the layer (sftimestats.txt:
  # from the capture's start, the app's start or savestate's load included):
  # its frames and present-to-present histogram (1 ms buckets, then wider);
  # the busiest layer whose name holds SF_TIMESTATS_LAYER (or SF_LAYER_ANY)
  case "$sf" in ''|,NA*)
    if [ -s "$R/sftimestats.txt" ]; then
      sf=$(awk -v pat="$SF_TIMESTATS_LAYER" -v any="$SF_LAYER_ANY" '
        /^layerName = / { cur = (index($0, pat) || (any != "" && index($0, any))); tot = 0; next }
        cur && /^totalFrames = / { tot = $3 + 0; next }
        cur && /^present2present histogram/ { want = 1; next }
        want { want = 0
          if (tot <= best) next
          best = tot; nh = 0
          for (i = 1; i <= NF; i++) { split($i, kv, "="); ms = kv[1]; sub(/ms$/, "", ms); if (kv[2] + 0 > 0) { h[++nh] = ms + 0; c[nh] = kv[2] + 0 } }
          nhb = nh; for (i = 1; i <= nh; i++) { hb[i] = h[i]; cb[i] = c[i] }
        }
        END {
          if (!best || !nhb) { print ",NA,NA,NA,NA,NA"; exit }
          for (i = 1; i <= nhb; i++) all += cb[i]
          for (i = 1; i <= nhb && acc * 2 < all; i++) { acc += cb[i]; med = hb[i] }
          for (i = 1; i <= nhb; i++) { if (hb[i] > 1.5 * med) g += cb[i]; if (hb[i] > worst) worst = hb[i] }
          printf ",%d,%d,%.1f,%.1f,timestats\n", best, g, worst, med
        }' "$R/sftimestats.txt")
    fi
  esac
  [ -n "$sf" ] || sf=",NA,NA,NA,NA,NA"
  csv_kv "sf_frames sf_gaps sf_worst_gap_ms sf_median_ms sf_source" "$sf" >> "$V"
  ad_report_extra "$R" "$spid" "$w0" "$w1" >> "$V"
  # an app without its own frame log: its frames, stutters (SurfaceFlinger's
  # gaps) and worst gap from SurfaceFlinger, over the window
  grep -q '^secs=' "$V" || awk -v a="$w0" -v b="$w1" 'BEGIN { d = b - a; if (d < 0) d += 86400; printf "secs=%.1f\n", d }' >> "$V"
  if ! grep -q '^fps=' "$V"; then
    awk -F= '{ v[$1] = $2 } END {
      s = v["secs"] + 0; f = v["sf_frames"]; g = v["sf_gaps"]
      if (f != "NA" && f != "") printf "frames=%d\nfps=%.1f\n", f, (s > 0 ? f / s : 0)
      if (g != "NA" && g != "") printf "stutters=%d\nper_min=%.1f\nworst_ms=%s\n", g, (s > 0 ? g * 60 / s : 0), v["sf_worst_gap_ms"]
    }' "$V" >> "$V.2" && cat "$V.2" >> "$V"; rm -f "$V.2"
  fi
  row "$V" >> "$SUM"
  rm -f "$V"
done
rm -f "$B/.groups" "$B/.regroup"

# ---- the report's sections (core; the adapter's are ad_section_<name>) ----
# the variants side by side
section_main() {
  awk -F, "$COLS"'
    function num(x) { return x != "NA" && x != "" }
    function add(k, x) { if (num(x)) { s[k, v] += x; n[k, v]++ } }
    function avg(k, f, w) { return n[k, v] ? sprintf(f, s[k, v] / n[k, v]) : sprintf("%" w "s", "NA") }
    function sum(k, f, w) { return n[k, v] ? sprintf(f, s[k, v]) : sprintf("%" w "s", "NA") }
    c("kind") == "measure" { v = c("variant"); if (!(v in runs)) order[++nv] = v
      runs[v]++; add("fps", c("fps")); add("pm", c("per_min")); add("st", c("stutters")); add("ov", c("over_ms"))
      x = c("worst_ms"); if (num(x)) { if (!((v) in wst) || x + 0 > wst[v]) wst[v] = x + 0 }
      add("hg", c("hangs")); add("tmp", c("max_gpuss_C")) }
    END {
      printf "%-22s %4s %7s %9s %10s %10s %8s %6s %9s\n", "variant", "runs", "fps", "stutters", "per min", "over ms", "worst", "hangs", "gpuss C"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %4d %s %s %s %s %s %s %s\n", v, runs[v], avg("fps", "%7.1f", 7), avg("st", "%9.1f", 9), avg("pm", "%10.1f", 10),
          avg("ov", "%10.0f", 10), ((v in wst) ? sprintf("%8.1f", wst[v]) : sprintf("%8s", "NA")), sum("hg", "%6d", 6), avg("tmp", "%9.1f", 9) }
    }' "$SUM"
  [ -z "$MAIN_NOTE" ] || echo "$MAIN_NOTE"
}

# each thread's run and wait (THREADS; headings THREAD_LABELS: top/bottom, _ a space)
section_threads() {
  echo "Threads (averages per run, ms over the $WINDOW_WORD; run = on a CPU, wait = ready but no CPU free):"
  awk -F, -v threads="$THREADS" -v labels="$THREAD_LABELS" "$COLS"'
    function add(k, x) { if (x != "NA") { s[k, v] += x; cn[k, v]++ } }
    function avg(k) { return cn[k, v] ? sprintf("%.0f", s[k, v] / cn[k, v]) : "NA" }
    BEGIN { nt = split(threads, ts, " "); split(labels, ls, " ")
      for (i = 1; i <= nt; i++) { k[i] = ts[i]; sub(/=.*/, "", k[i]); tn[i] = ts[i]; sub(/^[^=]*=/, "", tn[i])
        if (ls[i] != "") { top[i] = ls[i]; sub(/\/.*/, "", top[i]); bot[i] = ls[i]; sub(/^[^\/]*\//, "", bot[i]); gsub(/_/, " ", top[i]); gsub(/_/, " ", bot[i]) }
        else { top[i] = k[i]; bot[i] = substr(tn[i], 1, 9) } } }
    c("kind") == "measure" { v = c("variant"); if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      add("start", c("start_gpuss_C"))
      for (i = 1; i <= nt; i++) { add(k[i] "_run", c(k[i] "_run_ms")); add(k[i] "_wait", c(k[i] "_wait_ms")) } }
    END {
      h1 = sprintf("%-22s %7s", "variant", "start C"); h2 = sprintf("%-22s %7s", "", "")
      for (i = 1; i <= nt; i++) { h1 = h1 sprintf(" %9s %9s", top[i], "wait"); h2 = h2 sprintf(" %9s %9s", bot[i], "") }
      print h1; print h2
      for (j = 1; j <= nv; j++) { v = order[j]; l = sprintf("%-22s %7s", v, avg("start"))
        for (i = 1; i <= nt; i++) l = l sprintf(" %9s %9s", avg(k[i] "_run"), avg(k[i] "_wait"))
        print l }
    }' "$SUM"
}

# what SurfaceFlinger presented of the app's layer
section_display() {
  echo "Display (averages per run; SF = what SurfaceFlinger presented of $SF_LABEL, gaps = over 1.5x the median frame interval):"
  awk -F, "$COLS"'
    function add(k, x) { if (x != "NA") { s[k, v] += x; n[k, v]++ } }
    function avg(k, f) { return n[k, v] ? sprintf(f, s[k, v] / n[k, v]) : "NA" }
    c("kind") == "measure" { v = c("variant"); if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      add("sf_frames", c("sf_frames")); add("sf_gaps", c("sf_gaps")); add("sf_median_ms", c("sf_median_ms"))
      x = c("sf_worst_gap_ms"); if (x != "NA" && (!(v in wst) || x + 0 > wst[v])) wst[v] = x + 0
      if (!((v, c("sf_source")) in src)) { src[v, c("sf_source")] = 1; srcs[v] = srcs[v] (srcs[v] == "" ? "" : "+") c("sf_source") } }
    END {
      printf "%-22s %9s %8s %9s %9s  %s\n", "variant", "SF frames", "SF gaps", "SF worst", "SF median", "SF source"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %9s %8s %9s %9s  %s\n", v, avg("sf_frames", "%.0f"), avg("sf_gaps", "%.0f"),
          (v in wst) ? sprintf("%.1f", wst[v]) : "NA", avg("sf_median_ms", "%.1f"), srcs[v] }
    }' "$SUM"
}

# the busiest threads of the app over the window, by name (any app: no THREADS needed)
section_busiest() {
  echo "Busiest threads (averages per run over the window, ms; by name, threads of one name summed):"
  for R in "$B"/*/; do
    R=${R%/}
    grep -q '^kind=measure' "$R/run.txt" 2>/dev/null || continue
    grep -q '^failed=' "$R/run.txt" 2>/dev/null && continue
    [ -s "$R/schedstat_start.txt" ] && [ -s "$R/schedstat_end.txt" ] || continue
    v=$(awk -F, -v r="${R##*/}" 'NR > 1 && $1 == r { print $2 }' "$SUM")
    [ -n "$v" ] || continue
    awk -v v="$v" -v run="${R##*/}" '
      function name(  i, n) { n = $6; for (i = 7; i <= NF; i++) n = n " " $i; return n }
      FNR == NR { r0[$1] = $2; w0[$1] = $3; next }
      $2 ~ /^[0-9]+$/ { dr = $2 - r0[$1]; dw = $3 - w0[$1]; if (dr < 0 || dw < 0) next
        n = name(); r[n] += dr; w[n] += dw }
      END { for (n in r) printf "%s\t%s\t%s\t%.0f\t%.0f\n", v, run, n, r[n] / 1e6, w[n] / 1e6 }' "$R/schedstat_start.txt" "$R/schedstat_end.txt"
  done > "$B/.busy"
  if [ -s "$B/.busy" ]; then
    # per variant: each name's run and wait over the runs it has snapshots of, the 8 busiest
    awk -F'\t' '{ if (!($1 in seen)) { seen[$1] = 1; order[++nv] = $1 }
        if (!(($1, $2) in rs)) { rs[$1, $2] = 1; nr[$1]++ }
        k = $1 SUBSEP $3; if (!(k in has)) { has[k] = 1; nm[$1, ++nn[$1]] = $3 }
        r[k] += $4; w[k] += $5 }
      END {
        printf "%-22s %-16s %9s %9s\n", "variant", "thread", "run", "wait"
        for (i = 1; i <= nv; i++) { v = order[i]; m = nn[v]
          for (a = 1; a <= m; a++) idx[a] = a
          for (a = 2; a <= m; a++) { x = idx[a]; for (b = a - 1; b >= 1 && r[v, nm[v, idx[b]]] < r[v, nm[v, x]]; b--) idx[b + 1] = idx[b]; idx[b + 1] = x }
          for (a = 1; a <= m && a <= 8; a++) { t = nm[v, idx[a]]
            printf "%-22s %-16s %9.0f %9.0f\n", (a == 1 ? v : ""), t, r[v, t] / nr[v], w[v, t] / nr[v] } }
      }' "$B/.busy"
  else
    echo "  none (no schedstat snapshots)"
  fi
  rm -f "$B/.busy"
}

section_failed() {
  echo "Failed runs (their check failed: kept out of everything above):"
  if [ -s "$B/failed.txt" ]; then
    awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }' "$B/failed.txt"
  else
    echo "  none"
  fi
}

section_probes() {
  echo "Probe runs (not in the comparisons above; their collectors cost CPU):"
  awk -F, "$COLS"'c("kind") != "measure" { printf "  %-32s %-12s %6.1f fps %4d stutters (%5.1f/min)\n", c("run"), c("kind"), c("fps"), c("stutters"), c("per_min"); n++ }
    END { if (!n) print "  none" }' "$SUM"
  for R in "$B"/*/; do
    st=$(grep -E '^probe_' "$R/run.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    [ -n "$st" ] && echo "    ${R#$B/}: $st"
    for f in trace.pftrace perf.data simpleperf_symbols.txt simpleperf_threads.txt perfetto.txt simpleperf.txt; do
      [ -s "$R$f" ] && echo "    ${R#$B/}$f ($(wc -c < "$R$f" | tr -d ' ') bytes)"
    done
  done
}

section_perrun() {
  echo "Per run:"
  awk -F, "$COLS"'{ printf "  %-24s %-18s %6.1f s %6.1f fps %4d stutters (%5.1f/min), worst %6.1f ms, caps big/prime %s/%s kHz, gpuss %s C\n",
      c("run"), c("variant"), c("secs"), c("fps"), c("stutters"), c("per_min"), c("worst_ms"), c("min_cap_big_khz"), c("min_cap_prime_khz"), c("max_gpuss_C")
    '"$PERRUN_AWK"' }' "$SUM"
}

{
  echo "$REPORT_TITLE: $B"
  echo
  if [ -s "$B/inputs.txt" ]; then
    echo "Inputs changed within the batch: a scene's runs grouped by what they started from (inputs.txt):"
    awk -F'\t' '{ printf "  %-14s %s (%s)\n", $1, $2, $3 }' "$B/inputs.txt"
    echo
  fi
  first=1
  for s in $REPORT_SECTIONS; do
    [ -n "$first" ] || echo
    first=
    if command -v "ad_section_$s" > /dev/null 2>&1; then "ad_section_$s"; else "section_$s"; fi
  done
} > "$B/report.txt"
cat "$B/report.txt"
