#!/system/bin/sh
# hakuX route batch report: what each replay of a route stuttered, and the
# variants (switch settings) side by side. Plain sh + POSIX awk: runs on the
# phone (route.sh calls it after a batch) or on any PC with sh and awk.
#   sh route_report.sh <batch dir>     writes summary.csv and report.txt there
# A batch dir holds one dir per run (logcat.txt, sensors.csv, run.txt).
B=${1:?usage: sh route_report.sh <batch dir>}
SUM=$B/summary.csv
echo "run,variant,secs,frames,fps,stutters,per_min,over_ms,worst_ms,hangs,work_ms,max_gpuss_C,max_batt_C,min_cap_big_khz,min_cap_prime_khz,cpu7_avg_khz,gpu_avg_mhz,vbl_answer_avg_ms,vbl_answer_max_ms,vbl_over_2ms,vbl_over_8ms,vbl_unanswered,flip_delay_avg_ms,flip_delay_max_ms,present_interval_start,present_interval_changes,present_interval_values,kind,start_gpuss_C,vcpu_run_ms,vcpu_wait_ms,decode_run_ms,decode_wait_ms,render_run_ms,render_wait_ms,main_run_ms,main_wait_ms,apu_run_ms,apu_wait_ms,jit_drops,jit_drops_max_10s,sf_frames,sf_gaps,sf_worst_gap_ms,sf_median_ms,sf_source,mods" > "$SUM"
: > "$B/reasons.txt"; : > "$B/watch.txt"; : > "$B/failed.txt"

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
  mods=$(sed -n 's/^mods_applied=//p' "$R/run.txt" 2>/dev/null | tr ' ' '+')
  grep -q '^mods_applied=' "$R/run.txt" 2>/dev/null && mods=${mods:-none}
  scene=$(sed -n 's/^scene=//p' "$R/run.txt" 2>/dev/null)
  variant=${variant:-default}
  [ -n "$scene" ] && variant=$scene/$variant          # compared within a scene
  [ "$kind" = measure ] || variant=$variant/probe-$kind
  start_c=$(sed -n 's/^start_gpuss_C=//p' "$R/run.txt" 2>/dev/null)
  # the watched guest word that is the presentation interval (route.sh's
  # debug.hakux.watch; D3D's 0x862494 in Fable), as the watch log writes it
  waddr=$(sed -n 's/^debug.hakux.watch=//p' "$R/run.txt" 2>/dev/null | cut -d, -f1)
  waddr=$(printf '%08x' "$(( ${waddr:-0x862494} ))")
  # the replay's window and its stutters, from hakuX's log (logcat -v time)
  rs=$B/reasons.txt; [ "$kind" = measure ] || rs=/dev/null   # probes: not in the causes
  awk -v run="$run" -v variant="$variant" -v reasons="$rs" -v winf="$R/.window" \
      -v waddr="$waddr" -v watchf="$B/watch.txt" '
    function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    function msg(line) { sub(/^[^)]*\): /, "", line); return line }
    # a guest word as a number where small (the interval: 1, 2...), else hex
    function word(h,  d, i, c) {
      sub(/^0+/, "", h); if (h == "") return 0
      if (length(h) > 4) return "0x" h
      d = 0; for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; d = d * 16 + c }
      return d
    }
    /pad script: started/ { t0 = secs($2); started = 1; spid = pid($0); next }
    # the watch: each process logs the word once at its start, then on each
    # change; the replaying process: its first value is the start, its changes
    # inside the window are counted (the log comes before the window filter)
    /hakuX-native-watch/ && / = [0-9a-f]+ \(was [0-9a-f]+\) at vblank/ {
      m = msg($0); split(m, wv, " ")
      if (wv[1] != waddr) next
      p = pid($0); val = word(wv[3])
      if (!(p in wfirst)) { wfirst[p] = val; next }
      if (started && !done && p == spid) {
        pich++; pivals = pivals (pivals == "" ? wfirst[p] : "") ">" val
        print run "\t" variant "\t" $2 "\t" word(substr(wv[5], 1, 8)) "\t" val "\t" wv[8] >> watchf
      }
      next
    }
    /pad script: done/ {
      t1 = secs($2)
      if (match($0, /frame [0-9]+, [0-9]+ ms/)) {
        split(substr($0, RSTART, RLENGTH), d, /[ ,]+/); frames = d[2]; ms = d[3]
      }
      done = 1; next
    }
    !started || done { next }
    # FEX code thrown away (the guest wrote over translated code: the Fable pager)
    /translations of .* dropped/ {
      jit++; bk = int((secs($2) - t0) / 10); jb[bk]++; if (jb[bk] > jmax) jmax = jb[bk]
      next
    }
    /hakuX-native-vbl.*vblank answered/ {
      split(msg($0), b, " ")               # vblank answered N times: avg A max M ms, X over 2 ms, ...
      vn += b[3]; vsum += b[3] * b[6]; if (b[8] > vmax) vmax = b[8]
      v2 += b[10]; v8 += b[14]; vmiss += b[18]
      sub(/:$/, "", b[22]); fn += b[22]; fsum += b[22] * b[23]; if (b[25] > fmax) fmax = b[25]
      nvbl++
      next
    }
    /hakuX-native-perf.*last 10 s:/ {
      if (match($0, /work [0-9.]+ ms/)) { split(substr($0, RSTART, RLENGTH), w, " "); work += w[2]; nwork++ }
      next
    }
    /hakuX-hle-hitch/ && /(stutter|HANG) #[0-9]+ frame/ {
      line = $0; sub(/^[^)]*\): /, "", line)    # the message, after "I/tag( pid): "
      hang = line ~ /^HANG/
      if (match(line, /front [0-9.]+ ms after the last \(expected [0-9.]+\)/)) {
        split(substr(line, RSTART, RLENGTH), v, /[ ()]+/); got = v[2]; expd = v[8]
        why = line; sub(/^[^|]*dropped: /, "", why)
      } else if (match(line, /: [0-9.]+ (ms|s) \(expected [0-9.]+/)) {
        split(substr(line, RSTART, RLENGTH), v, /[ ()]+/); got = v[2]; expd = v[5]
        if (v[3] == "s") got *= 1000
        why = substr(line, RSTART + RLENGTH); sub(/^[^)]*\): /, "", why)
      } else next
      sub(/ \|.*$/, "", why); gsub(/[0-9]+(\.[0-9]+)?/, "#", why)
      n++; hangs += hang; over += got - expd; if (got > worst) worst = got
      print variant "\t" got - expd "\t" why >> reasons
      next
    }
    END {
      if (!started) { printf "%s: no \"pad script: started\" (the replay did not run)\n", run > "/dev/stderr"; exit 1 }
      if (!done) { t1 = t0; printf "%s: no \"pad script: done\" (cut short)\n", run > "/dev/stderr" }
      dur = (ms ? ms / 1000 : t1 - t0); if (dur < 0) dur += 86400
      printf "%s,%s,%.1f,%d,%.1f,%d,%.1f,%.0f,%.1f,%d,%.2f,%.1f,%.1f,%s,%s,%s,%s",
        run, variant, dur, frames, (dur > 0 ? frames / dur : 0), n, (dur > 0 ? n * 60 / dur : 0),
        over, worst, hangs, (nwork ? work / nwork : 0), 0, 0, "NA", "NA", "NA", "NA"
      if (nvbl)                            # NA: no vblank log (a build before optimized-test-v3)
        printf ",%.2f,%.2f,%d,%d,%d,%.2f,%.2f", (vn ? vsum / vn : 0), vmax, v2, v8, vmiss, (fn ? fsum / fn : 0), fmax
      else
        printf ",NA,NA,NA,NA,NA,NA,NA"
      printf ",%s,%d,%s", (spid in wfirst ? wfirst[spid] : "NA"), pich, (pivals == "" ? "-" : pivals)
      printf "\n"
      print t0, t1, spid, jit + 0, jmax + 0 > winf
    }
  ' "$R/logcat.txt" > "$R/.row" || continue
  read -r w0 w1 spid jit jitmax < "$R/.window"
  win="$w0 $w1"
  # clocks, caps and temperatures inside the window (session.sh's sensors.csv)
  if [ -f "$R/sensors.csv" ]; then
    awk -F, -v win="$win" -v row="$(cat "$R/.row")" '
      function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
      function num(x) { return x != "NA" && x != "" }
      BEGIN { split(win, w, " "); t0 = w[1]; t1 = w[2]; capb = capp = "" }
      NR == 1 { next }
      { t = secs($1); if (t < t0 - 5 || t > t1 + 5) next
        if (num($9) && $9 / 1000 > gpuss) gpuss = $9 / 1000
        if (num($10) && $10 / 10 > batt) batt = $10 / 10
        if (num($14) && (capb == "" || $14 < capb)) capb = $14
        if (num($15) && (capp == "" || $15 < capp)) capp = $15
        if (num($8)) { c7 += $8; n7++ }
        if (num($2)) { g += $2; ng++ } }
      END {
        n = split(row, f, ",")
        f[12] = sprintf("%.1f", gpuss); f[13] = sprintf("%.1f", batt)
        f[14] = capb == "" ? "NA" : capb; f[15] = capp == "" ? "NA" : capp
        f[16] = n7 ? sprintf("%.0f", c7 / n7) : "NA"; f[17] = ng ? sprintf("%.0f", g / ng) : "NA"
        out = f[1]; for (i = 2; i <= n; i++) out = out "," f[i]; print out
      }' "$R/sensors.csv" > "$R/.row2" && mv "$R/.row2" "$R/.row"
  fi
  # each thread's time on a CPU and waiting for one (run-queue wait) during
  # the replay, from its schedstat at the replay's start and end (lines:
  # tid run_ns wait_ns slices last_cpu name), by thread name: SDLThread (the
  # vCPU: the tid hakuX logs for it, else the busiest SDLThread), hle-pb
  # (the decoder), hle.render, SDLActivity (the app's main thread), apu.frame;
  # a name held by several threads: the busiest. A thread started after the
  # first snapshot counts from 0.
  vtid=$(awk -v spid="$spid" '
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    pid($0) == spid && /hakuX-native-perf.*thread vCPU: tid [0-9]+/ { t = $NF }
    pid($0) == spid && /hakuX-native-perf.*hint session: .*\(vCPU [0-9]+/ && !t {
      m = $0; sub(/^.*\(vCPU /, "", m); sub(/[^0-9].*$/, "", m); t = m }
    END { print t + 0 }' "$R/logcat.txt")
  if [ -s "$R/schedstat_start.txt" ] && [ -s "$R/schedstat_end.txt" ]; then
    sched=$(awk -v vtid="$vtid" '
      function name(  i, n) { n = $6; for (i = 7; i <= NF; i++) n = n " " $i; return n }
      FNR == NR { r0[$1] = $2; w0[$1] = $3; next }
      $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
        n = name(); dr = $2 - r0[$1]; dw = $3 - w0[$1]
        if (dr < 0 || dw < 0) next           # another thread with a reused tid
        if ($1 == vtid && n == "SDLThread") { vr = dr; vw = dw; vset = 1 }
        if (!(n in br) || dr > br[n]) { br[n] = dr; bw[n] = dw }
      }
      function col(n) { return (n in br) ? sprintf(",%.0f,%.0f", br[n] / 1e6, bw[n] / 1e6) : ",NA,NA" }
      END {
        if (vset) { br["SDLThread"] = vr; bw["SDLThread"] = vw }
        print col("SDLThread") col("hle-pb") col("hle.render") col("SDLActivity") col("apu.frame")
      }' "$R/schedstat_start.txt" "$R/schedstat_end.txt")
  else
    sched=",NA,NA,NA,NA,NA,NA,NA,NA,NA,NA"
  fi
  # what the display presented: SurfaceFlinger's actual present times of
  # hakuX's layer (sflatency.txt: a block of its last 127 frames every 2 s,
  # under "## HH:MM:SS <layer>"). Present times are the monotonic clock: a
  # block's newest frame against its wall time gives the offset that puts
  # them in the replay's window. Frames counted once; gaps only between
  # neighbours in the same block (two blocks may not meet). Gaps: over 1.5
  # times the median frame interval (16.7 ms at 60 fps, 25 at 40).
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
  # from the capture's start, the savestate's load included): its frames
  # and present-to-present histogram (1 ms buckets, then wider)
  case "$sf" in ''|,NA*)
    if [ -s "$R/sftimestats.txt" ]; then
      sf=$(awk '
        /^layerName = / { cur = ($0 ~ /SurfaceView\[com\.rfandango\.haku_x/); tot = 0; next }
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
  echo "$(cat "$R/.row"),$kind,${start_c:-NA}$sched,$jit,$jitmax$sf,${mods:-NA}" >> "$SUM"
  rm -f "$R/.row" "$R/.window"
done

# the variants side by side, then each one's commonest stutter causes
{
  echo "hakuX route report: $B"
  echo
  awk -F, 'NR > 1 && $28 == "measure" { v = $2; if (!(v in runs)) order[++nv] = v
      runs[v]++; fps[v] += $5; pm[v] += $7; st[v] += $6; ov[v] += $8; if ($9 > wst[v]) wst[v] = $9
      hg[v] += $10; tmp[v] += $12 }
    END {
      printf "%-22s %4s %7s %9s %10s %10s %8s %6s %9s\n", "variant", "runs", "fps", "stutters", "per min", "over ms", "worst", "hangs", "gpuss C"
      for (i = 1; i <= nv; i++) { v = order[i]; r = runs[v]
        printf "%-22s %4d %7.1f %9.1f %10.1f %10.0f %8.1f %6d %9.1f\n", v, r, fps[v] / r, st[v] / r, pm[v] / r, ov[v] / r, wst[v], hg[v], tmp[v] / r }
    }' "$SUM"
  echo
  echo "Vblanks (the title's handler answering each vblank, and its flips after them; averages per run):"
  awk -F, 'NR > 1 && $28 == "measure" && $18 != "NA" { v = $2; if (!(v in runs)) order[++nv] = v
      runs[v]++; a[v] += $18; if ($19 > mx[v]) mx[v] = $19; o2[v] += $20; o8[v] += $21; un[v] += $22
      fa[v] += $23; if ($24 > fm[v]) fm[v] = $24; pc[v] += $26 }
    END {
      if (!nv) { print "  (no vblank log: the build is older than optimized-test-v3)"; exit }
      printf "%-22s %4s %9s %9s %9s %9s %11s %10s %10s %10s\n", "variant", "runs", "answer ms", "worst ms", ">2 ms", ">8 ms", "unanswered", "flip ms", "flip worst", "PI changes"
      for (i = 1; i <= nv; i++) { v = order[i]; r = runs[v]
        printf "%-22s %4d %9.2f %9.2f %9.1f %9.1f %11.1f %10.2f %10.2f %10.1f\n", v, r, a[v] / r, mx[v], o2[v] / r, o8[v] / r, un[v] / r, fa[v] / r, fm[v], pc[v] / r }
    }' "$SUM"
  echo
  echo "Threads (averages per run, ms over the replay; run = on a CPU, wait = ready but no CPU free):"
  awk -F, 'function add(k, x) { if (x != "NA") { s[k, v] += x; c[k, v]++ } }
    function avg(k) { return c[k, v] ? sprintf("%.0f", s[k, v] / c[k, v]) : "NA" }
    NR > 1 && $28 == "measure" { v = $2; if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      for (i = 29; i <= 39; i++) add(i, $i) }
    END {
      printf "%-22s %7s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s\n", "variant", "start C",
        "vCPU run", "wait", "decode", "wait", "render", "wait", "main", "wait", "apu", "wait"
      printf "%-22s %7s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s\n", "", "",
        "SDLThread", "", "hle-pb", "", "hle.rendr", "", "SDLActvty", "", "apu.frame", ""
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %7s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s\n", v, avg(29), avg(30), avg(31), avg(32), avg(33), avg(34), avg(35), avg(36), avg(37), avg(38), avg(39) }
    }' "$SUM"
  echo
  echo "JIT and display (averages per run; SF = what SurfaceFlinger presented of hakuX's layer, gaps = over 1.5x the median frame interval):"
  awk -F, 'function add(k, x) { if (x != "NA") { s[k, v] += x; c[k, v]++ } }
    function avg(k, f) { return c[k, v] ? sprintf(f, s[k, v] / c[k, v]) : "NA" }
    NR > 1 && $28 == "measure" { v = $2; if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      for (i = 40; i <= 43; i++) add(i, $i); if ($44 != "NA" && $44 > wst[v]) wst[v] = $44; add(45, $45)
      if (!((v, $46) in src)) { src[v, $46] = 1; srcs[v] = srcs[v] (srcs[v] == "" ? "" : "+") $46 }
      if (!((v, $47) in md)) { md[v, $47] = 1; mods[v] = mods[v] (mods[v] == "" ? "" : " ") $47 } }
    END {
      printf "%-22s %7s %9s %9s %8s %9s %9s %10s %-10s %s\n", "variant", "JIT", "JIT/10s", "SF frames", "SF gaps", "SF worst", "SF median", "", "SF source", "mods applied"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %7s %9s %9s %8s %9s %9s %10s %-10s %s\n", v, avg(40, "%.0f"), avg(41, "%.0f"), avg(42, "%.0f"), avg(43, "%.0f"),
          (v in wst) ? sprintf("%.1f", wst[v]) : "NA", avg(45, "%.1f"), "", srcs[v], mods[v] }
    }' "$SUM"
  echo
  echo "Failed runs (their check failed: kept out of everything above):"
  if [ -s "$B/failed.txt" ]; then
    awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }' "$B/failed.txt"
  else
    echo "  none"
  fi
  echo
  echo "Probe runs (not in the comparisons above; their collectors cost CPU):"
  awk -F, 'NR > 1 && $28 != "measure" { printf "  %-32s %-12s %6.1f fps %4d stutters (%5.1f/min)\n", $1, $28, $5, $6, $7; n++ }
    END { if (!n) print "  none" }' "$SUM"
  for R in "$B"/*/; do
    st=$(grep -E '^probe_' "$R/run.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    [ -n "$st" ] && echo "    ${R#$B/}: $st"
    for f in trace.pftrace perf.data simpleperf_symbols.txt simpleperf_threads.txt perfetto.txt simpleperf.txt; do
      [ -s "$R$f" ] && echo "    ${R#$B/}$f ($(wc -c < "$R$f" | tr -d ' ') bytes)"
    done
  done
  echo
  echo "Per run:"
  awk -F, 'NR > 1 { printf "  %-24s %-18s %6.1f s %6.1f fps %4d stutters (%5.1f/min), worst %6.1f ms, caps big/prime %s/%s kHz, gpuss %s C\n",
      $1, $2, $3, $5, $6, $7, $9, $14, $15, $12
      if ($18 != "NA")
        printf "  %-24s vblank answer %s avg %s max ms, %s over 2 ms, %s over 8 ms, %s unanswered; flips %s avg %s max ms after; interval %s, %s changes (%s)\n",
          "", $18, $19, $20, $21, $22, $23, $24, $25, $26, $27 }' "$SUM"
  echo
  echo "Presentation interval changes during the replays (run, time, from > to, at vblank):"
  if [ -s "$B/watch.txt" ]; then
    awk -F'\t' '{ printf "  %-24s %s  %s > %s  (vblank %s)\n", $1, $3, $4, $5, $6 }' "$B/watch.txt"
  else
    echo "  none"
  fi
  echo
  echo "Commonest causes (count, ms over the expected frame time in all; per variant):"
  awk -F'\t' '{ k = $1 "\t" $3; if (!(k in n)) keys[++nk] = k; n[k]++; ms[k] += $2 }
    END { for (i = 1; i <= nk; i++) { k = keys[i]; split(k, p, "\t")
            printf "%s\t%d\t%.0f\t%s\n", p[1], n[k], ms[k], p[2] } }' "$B/reasons.txt" |
    sort -t "$(printf '\t')" -k1,1 -k3,3nr |
    awk -F'\t' '{ if ($1 != last) { print "  " $1 ":"; shown = 0; last = $1 }
                  if (shown++ < 8) printf "    %4d x %7s ms  %s\n", $2, $3, $4 }'
} > "$B/report.txt"
cat "$B/report.txt"
