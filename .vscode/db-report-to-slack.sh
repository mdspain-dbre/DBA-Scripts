#!/usr/bin/env bash
# db-report-to-slack.sh — READ-ONLY fleet control-plane health summary -> Slack.
# Sweeps CloudSQL + AlloyDB across the given projects, flags backups-off / SSL-not-enforced,
# adds 6h CPU/mem peaks (Cloud Monitoring), and posts via send-slack.sh.
# Usage: db-report-to-slack.sh [channel_id_or_#name] [project ...]
#   defaults: channel C0AE84DBWRZ (DRE Denver); projects = inscape dev/qa/stage
#   dry run:  SLACK_SENDER=/tmp/drycat db-report-to-slack.sh   (stub that just `cat`s stdin)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEND="${SLACK_SENDER:-$HERE/send-slack.sh}"
command -v gcloud >/dev/null || { echo "[ERROR] gcloud required." >&2; exit 1; }
command -v jq     >/dev/null || { echo "[ERROR] jq required." >&2; exit 1; }
[ -x "$SEND" ]              || { echo "[ERROR] sender not executable at $SEND" >&2; exit 1; }

CHANNEL="${1:-C0AE84DBWRZ}"; [ $# -gt 0 ] && shift
PROJECTS=("$@")
[ ${#PROJECTS[@]} -eq 0 ] && PROJECTS=(vz-inscape-portfolio-dev vz-inscape-portfolio-qa vz-inscape-portfolio-stage)

TOK=$(gcloud auth print-access-token 2>/dev/null || true)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# peak <metric> <project> <database_id> -> "NN%" or "n/a" (6h ALIGN_MAX, fraction*100)
peak() {
  local metric=$1 proj=$2 id=$3
  [ -z "$TOK" ] && { printf 'n/a'; return; }
  curl -s -H "Authorization: Bearer $TOK" -G \
    "https://monitoring.googleapis.com/v3/projects/$proj/timeSeries" \
    --data-urlencode "filter=metric.type=\"$metric\"" \
    --data-urlencode "interval.startTime=$START" \
    --data-urlencode "interval.endTime=$END" \
    --data-urlencode "aggregation.alignmentPeriod=300s" \
    --data-urlencode "aggregation.perSeriesAligner=ALIGN_MAX" 2>/dev/null \
  | jq -r --arg id "$id" '
      [.timeSeries[]? | select(.resource.labels.database_id==$id) | .points[].value.doubleValue] as $v
      | if ($v|length)>0 then (($v|max)*100|floor|tostring)+"%" else "n/a" end' 2>/dev/null || printf 'n/a'
}

R=":database: *DB Fleet Health — $(date -u +'%Y-%m-%d %H:%MZ')* (read-only)"
[ -z "$TOK" ] && R+=$'\n'"_:warning: no gcloud token — CPU/mem shown as n/a; run \`gcloud auth login\`._"

for p in "${PROJECTS[@]}"; do
  R+=$'\n\n'"*\`$p\`*"

  # ---- CloudSQL ----
  csql=$(gcloud sql instances list --project="$p" --format=json 2>/dev/null || echo '[]')
  if [ "$(echo "$csql" | jq 'length')" -eq 0 ]; then
    R+=$'\n'"• _no CloudSQL instances_"
  else
    # every column defaulted to a non-empty token so tab (IFS-whitespace) can't collapse/shift
    while IFS=$'\t' read -r name ver itype state backup ssl; do
      if [ "$itype" = "ON_PREMISES_INSTANCE" ]; then
        R+=$'\n'"• \`$name\` ($ver) _external primary — excluded_"
        continue
      fi
      f=""
      [ "$backup" = "false" ] && f+=" :red_circle: backups OFF"
      [ "$ssl" = "ALLOW_UNENCRYPTED_AND_ENCRYPTED" ] && f+=" :warning: SSL not enforced"
      [ "$state" != "RUNNABLE" ] && f+=" :warning: state=$state"
      cpu=$(peak "cloudsql.googleapis.com/database/cpu/utilization"    "$p" "$p:$name")
      mem=$(peak "cloudsql.googleapis.com/database/memory/utilization" "$p" "$p:$name")
      [ -z "$f" ] && f=" :white_check_mark:"
      tag=""; [ "$itype" = "READ_REPLICA_INSTANCE" ] && tag=" _(replica)_"
      R+=$'\n'"• \`$name\` ($ver)$tag cpu≤$cpu mem≤$mem$f"
    done < <(echo "$csql" | jq -r '.[] | [
        (.name // "-"),
        (.databaseVersion // "-"),
        (.instanceType // "-"),
        (.state // "UNKNOWN"),
        ((.settings.backupConfiguration.enabled // false)|tostring),
        (.settings.ipConfiguration.sslMode // "-")
      ] | @tsv')
  fi

  # ---- AlloyDB ----
  clusters=$(gcloud alloydb clusters list --project="$p" --region=- --format=json 2>/dev/null || echo '[]')
  if [ "$(echo "$clusters" | jq 'length')" -gt 0 ]; then
    while IFS=$'\t' read -r cpath cstate; do
      region=$(echo "$cpath" | sed -E 's#.*/locations/([^/]+)/.*#\1#')
      cid=$(echo "$cpath" | sed -E 's#.*/clusters/([^/]+)$#\1#')
      cf=":white_check_mark:"; [ "$cstate" != "READY" ] && cf=":warning: $cstate"
      R+=$'\n'"• AlloyDB \`$cid\` [$region] $cf"
      insts=$(gcloud alloydb instances list --cluster="$cid" --region="$region" --project="$p" --format=json 2>/dev/null || echo '[]')
      while IFS=$'\t' read -r iid itype istate; do
        inf=":white_check_mark:"; [ "$istate" != "READY" ] && inf=":warning: $istate"
        R+=$'\n'"    ◦ \`$iid\` ($itype) $inf"
      done < <(echo "$insts" | jq -r '.[] | [((.name // "-")|split("/")|.[-1]),(.instanceType // "-"),(.state // "UNKNOWN")] | @tsv')
    done < <(echo "$clusters" | jq -r '.[] | [(.name // "-"),(.state // "UNKNOWN")] | @tsv')
  fi
done

R+=$'\n\n'"_cpu≤/mem≤ = 6h peak (ALIGN_MAX). Control-plane + Monitoring only; no in-DB checks._"

printf '%s' "$R" | "$SEND" "$CHANNEL"
