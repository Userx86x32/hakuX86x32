#!/system/bin/sh
# hakuX route batch report: what each replay of a route stuttered, and the
# variants (switch settings) side by side. Plain sh + POSIX awk: runs on the
# phone (route.sh calls it after a batch) or on any PC with sh and awk.
#   sh route_report.sh <batch dir>     writes summary.csv and report.txt there
# A batch dir holds one dir per run (logcat.txt, sensors.csv, run.txt).
B=${1:?usage: sh route_report.sh <batch dir>}
SUM=$B/summary.csv
echo "run,variant,secs,frames,fps,stutters,per_min,over_ms,worst_ms,hangs,work_ms,max_gpuss_C,max_batt_C,min_cap_big_khz,min_cap_prime_khz,cpu7_avg_khz,gpu_avg_mhz,vbl_answer_avg_ms,vbl_answer_max_ms,vbl_over_2ms,vbl_over_8ms,vbl_unanswered,flip_delay_avg_ms,flip_delay_max_ms,present_interval_start,present_interval_changes,present_interval_values,kind,start_gpuss_C,wait_vcpu_ms,wait_render_ms,wait_decode_ms,wait_present_ms,run_vcpu_ms,jit_drops,jit_drops_max_10s,sf_frames,sf_gaps_20ms,sf_worst_gap_ms" > "$SUM"
: > "$B/reasons.txt"; : > "$B/watch.txt"

for R in "$B"/*/; do
  R=${R%/}
  [ -f "$R/logcat.txt" ] || continue
  run=${R##*/}
  variant=$(sed -n 's/^variant=//p' "$R/run.txt" 2>/dev/null)
  kind=$(sed -n 's/^kind=//p' "$R/run.txt" 2>/dev/null); kind=${kind:-measure}
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
  # each thread's run-queue wait during the replay: the tids hakuX logs for
  # its vCPU, render, decode and present threads (the replay's process),
  # their schedstat (time on a CPU, waiting for one; ns) at its start and end
  tids=$(awk -v spid="$spid" '
    function pid(line) { return match(line, /\( *[0-9]+\)/) ? substr(line, RSTART + 1, RLENGTH - 2) + 0 : -1 }
    pid($0) != spid { next }
    /hakuX-native-perf.*thread [a-zA-Z]+: tid [0-9]+/ {
      m = $0; sub(/^.*thread /, "", m); split(m, a, /[: ]+/); t[a[1]] = a[3]
    }
    /hakuX-native-perf.*hint session: .*\(vCPU/ {
      m = $0; sub(/^.*\(/, "", m); gsub(/[(),]/, " ", m); n = split(m, a, " ")
      for (i = 1; i < n; i += 2) if (!(a[i] in t)) t[a[i]] = a[i + 1]
    }
    END { printf "%s %s %s %s", t["vCPU"] + 0, t["render"] + 0, t["decode"] + 0, t["present"] + 0 }' "$R/logcat.txt")
  if [ -s "$R/schedstat_start.txt" ] && [ -s "$R/schedstat_end.txt" ]; then
    sched=$(awk -v tids="$tids" '
      FNR == NR { r0[$1] = $2; w0[$1] = $3; next }
      { r1[$1] = $2; w1[$1] = $3 }
      END {
        n = split(tids, t, " ")
        for (i = 1; i <= 4; i++) {
          k = t[i]; out = out "," ((k && (k in w1)) ? sprintf("%.0f", (w1[k] - w0[k]) / 1e6) : "NA")
        }
        k = t[1]; out = out "," ((k && (k in r1)) ? sprintf("%.0f", (r1[k] - r0[k]) / 1e6) : "NA")
        print out
      }' "$R/schedstat_start.txt" "$R/schedstat_end.txt")
  else
    sched=",NA,NA,NA,NA,NA"
  fi
  # what the display presented (SurfaceFlinger's actual present times of
  # hakuX's layer, from the blocks taken during the replay): frames, gaps
  # over 20 ms, the longest gap
  if [ -s "$R/sflatency.txt" ]; then
    sf=$(awk -v t0="$w0" -v t1="$w1" '
      function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
      /^## / { keep = (secs($2) >= t0 && secs($2) <= t1 + 2); next }
      keep && NF == 3 && $2 > 0 && $2 < 9e18 { print $2 }' "$R/sflatency.txt" | sort -n -u |
      awk 'NR > 1 { d = ($1 - p) / 1e6; if (d > 20) g++; if (d > m) m = d } { p = $1; n++ }
        END { if (n) printf ",%d,%d,%.1f", n, g, m; else printf ",NA,NA,NA" }')
  else
    sf=",NA,NA,NA"
  fi
  echo "$(cat "$R/.row"),$kind,${start_c:-NA}$sched,$jit,$jitmax$sf" >> "$SUM"
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
  echo "Threads, JIT and display (averages per run; wait = ms a thread was ready but had no CPU):"
  awk -F, 'function add(k, x) { if (x != "NA") { s[k, v] += x; c[k, v]++ } }
    function avg(k) { return c[k, v] ? sprintf("%.0f", s[k, v] / c[k, v]) : "NA" }
    NR > 1 && $28 == "measure" { v = $2; if (!(v in seen)) { seen[v] = 1; order[++nv] = v }
      for (i = 29; i <= 40; i++) add(i, $i) }
    END {
      printf "%-22s %7s %9s %7s %7s %8s %9s %7s %9s %9s %8s %8s\n", "variant", "start C", "vCPU wait", "render", "decode", "present", "vCPU run", "JIT", "JIT/10s", "SF frames", "SF gaps", "SF worst"
      for (i = 1; i <= nv; i++) { v = order[i]
        printf "%-22s %7s %9s %7s %7s %8s %9s %7s %9s %9s %8s %8s\n", v, avg(29), avg(30), avg(31), avg(32), avg(33), avg(34), avg(35), avg(36), avg(37), avg(38), avg(39) }
    }' "$SUM"
  echo
  echo "Probe runs (not in the comparisons above; their collectors cost CPU):"
  awk -F, 'NR > 1 && $28 != "measure" { printf "  %-32s %-12s %6.1f fps %4d stutters (%5.1f/min)\n", $1, $28, $5, $6, $7; n++ }
    END { if (!n) print "  none" }' "$SUM"
  for R in "$B"/*/; do
    for f in trace.pftrace perf.data simpleperf_symbols.txt simpleperf_threads.txt perfetto.txt simpleperf.txt; do
      [ -f "$R$f" ] && echo "    ${R#$B/}$f ($(wc -c < "$R$f" | tr -d ' ') bytes)"
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
