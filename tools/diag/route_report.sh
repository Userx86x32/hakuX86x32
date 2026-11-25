#!/system/bin/sh
# hakuX route batch report: what each replay of a route stuttered, and the
# variants (switch settings) side by side. Plain sh + POSIX awk: runs on the
# phone (route.sh calls it after a batch) or on any PC with sh and awk.
#   sh route_report.sh <batch dir>     writes summary.csv and report.txt there
# A batch dir holds one dir per run (logcat.txt, sensors.csv, run.txt).
B=${1:?usage: sh route_report.sh <batch dir>}
SUM=$B/summary.csv
echo "run,variant,secs,frames,fps,stutters,per_min,over_ms,worst_ms,hangs,work_ms,max_gpuss_C,max_batt_C,min_cap_big_khz,min_cap_prime_khz,cpu7_avg_khz,gpu_avg_mhz" > "$SUM"
: > "$B/reasons.txt"

for R in "$B"/*/; do
  R=${R%/}
  [ -f "$R/logcat.txt" ] || continue
  run=${R##*/}
  variant=$(sed -n 's/^variant=//p' "$R/run.txt" 2>/dev/null)
  # the replay's window and its stutters, from hakuX's log (logcat -v time)
  awk -v run="$run" -v variant="${variant:-default}" -v reasons="$B/reasons.txt" -v winf="$R/.window" '
    function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    /pad script: started/ { t0 = secs($2); started = 1; next }
    /pad script: done/ {
      t1 = secs($2)
      if (match($0, /frame [0-9]+, [0-9]+ ms/)) {
        split(substr($0, RSTART, RLENGTH), d, /[ ,]+/); frames = d[2]; ms = d[3]
      }
      done = 1; next
    }
    !started || done { next }
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
      printf "\n"
      print t0, t1 > winf
    }
  ' "$R/logcat.txt" > "$R/.row" || continue
  win=$(cat "$R/.window")
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
      }' "$R/sensors.csv" >> "$SUM"
  else
    cat "$R/.row" >> "$SUM"
  fi
  rm -f "$R/.row" "$R/.window"
done

# the variants side by side, then each one's commonest stutter causes
{
  echo "hakuX route report: $B"
  echo
  awk -F, 'NR > 1 { v = $2; if (!(v in runs)) order[++nv] = v
      runs[v]++; fps[v] += $5; pm[v] += $7; st[v] += $6; ov[v] += $8; if ($9 > wst[v]) wst[v] = $9
      hg[v] += $10; tmp[v] += $12 }
    END {
      printf "%-22s %4s %7s %9s %10s %10s %8s %6s %9s\n", "variant", "runs", "fps", "stutters", "per min", "over ms", "worst", "hangs", "gpuss C"
      for (i = 1; i <= nv; i++) { v = order[i]; r = runs[v]
        printf "%-22s %4d %7.1f %9.1f %10.1f %10.0f %8.1f %6d %9.1f\n", v, r, fps[v] / r, st[v] / r, pm[v] / r, ov[v] / r, wst[v], hg[v], tmp[v] / r }
    }' "$SUM"
  echo
  echo "Per run:"
  awk -F, 'NR > 1 { printf "  %-24s %-18s %6.1f s %6.1f fps %4d stutters (%5.1f/min), worst %6.1f ms, caps big/prime %s/%s kHz, gpuss %s C\n",
      $1, $2, $3, $5, $6, $7, $9, $14, $15, $12 }' "$SUM"
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
