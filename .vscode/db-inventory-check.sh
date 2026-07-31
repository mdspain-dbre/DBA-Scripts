#!/usr/bin/env bash
# Read-only DB inventory drift check — runs at VS Code startup (folderOpen task).
# Confirms the live CloudSQL + AlloyDB instance inventory across dev/qa/stage
# still matches what's documented in the connections instructions file, so that
# doc doesn't silently go stale.
#
# STRICTLY READ-ONLY: only *list* calls + reads the markdown doc. No describe,
# no patch/delete, no SQL. Always exits 0 (non-blocking at startup).
#
# Override the project set with DB_INV_PROJECTS (space-separated).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$SCRIPT_DIR/../.github/instructions/cloudsql-connections.instructions.md"
PROJECTS="${DB_INV_PROJECTS:-vz-inscape-portfolio-dev vz-inscape-portfolio-qa vz-inscape-portfolio-stage}"

# ---- preflight -------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
    echo "[SKIP] gcloud not found on PATH — skipping DB inventory check."
    exit 0
fi
if [ ! -f "$DOC" ]; then
    echo "[SKIP] connections doc not found at $DOC — skipping DB inventory check."
    exit 0
fi
if ! gcloud auth print-access-token >/dev/null 2>&1; then
    echo "[SKIP] gcloud not authenticated — run 'Cloud Auth Login' first. Skipping DB inventory check."
    exit 0
fi

VERIFIED=$(grep -oE 'Inventory last verified: [0-9-]+' "$DOC" | head -1 | sed 's/Inventory last verified: //')
echo "==> DB Inventory Drift Check (read-only)"
echo "    Source of truth: .github/instructions/cloudsql-connections.instructions.md${VERIFIED:+ (last verified $VERIFIED)}"
echo "    Projects: $PROJECTS"
echo ""

# ---- documented inventory (parsed from the markdown tables) ----------------
# Emits: <project>\t<instance>
# CloudSQL section  -> instance = 1st backticked token in a table row
# AlloyDB  section  -> instance = 2nd backticked token (col1 is the cluster)
documented() {
    awk '
        /^## CloudSQL instances/ { mode="cloudsql"; next }
        /^## AlloyDB/            { mode="alloydb";  next }
        /^### / {
            if (match($0, /vz-inscape-portfolio-[a-z]+/)) proj = substr($0, RSTART, RLENGTH)
            next
        }
        /^\|/ {
            n = 0; s = $0
            while (match(s, /`[^`]+`/)) {
                toks[++n] = substr(s, RSTART+1, RLENGTH-2)
                s = substr(s, RSTART+RLENGTH)
            }
            if (n == 0) next                      # header/separator rows have no backticks
            if (mode == "cloudsql")      name = toks[1]
            else if (mode == "alloydb")  name = (n >= 2 ? toks[2] : toks[1])
            else                         name = ""
            if (proj != "" && name != "") print proj "\t" name
            delete toks
        }
    ' "$DOC"
}

# ---- live inventory (list-only) --------------------------------------------
live() {
    local project="$1"
    gcloud sql instances list --project="$project" --format="value(name)" 2>/dev/null \
        | while read -r n; do [ -n "$n" ] && printf '%s\t%s\n' "$project" "$n"; done

    gcloud alloydb clusters list --project="$project" --region=- \
        --format="value(name)" 2>/dev/null \
    | while read -r cpath; do
        [ -z "$cpath" ] && continue
        local region cluster
        region=$(echo "$cpath"  | sed -E 's#.*/locations/([^/]+)/.*#\1#')
        cluster=$(echo "$cpath" | sed -E 's#.*/clusters/([^/]+)$#\1#')
        gcloud alloydb instances list --cluster="$cluster" --region="$region" \
            --project="$project" --format="value(name.basename())" 2>/dev/null \
            | while read -r i; do [ -n "$i" ] && printf '%s\t%s\n' "$project" "$i"; done
    done
}

DOC_ALL="$(documented | sort -u)"
drift=0

for project in $PROJECTS; do
    if ! gcloud projects describe "$project" >/dev/null 2>&1; then
        echo "### $project"
        echo "    [SKIP] project not accessible"
        echo ""
        continue
    fi

    doc_set=$(echo "$DOC_ALL" | awk -F'\t' -v p="$project" '$1==p{print $2}' | sort -u)
    live_set=$(live "$project" | awk -F'\t' '{print $2}' | sort -u)

    new_live=$(comm -13 <(echo "$doc_set") <(echo "$live_set"))   # live, not in doc
    gone=$(comm -23 <(echo "$doc_set") <(echo "$live_set"))       # doc, not live

    echo "### $project"
    if [ -z "$new_live" ] && [ -z "$gone" ]; then
        echo "    ✅ inventory in sync ($(echo "$live_set" | grep -c .) instances)"
    else
        drift=1
        [ -n "$new_live" ] && while read -r n; do
            [ -n "$n" ] && echo "    ➕ live but NOT documented: $n"
        done <<< "$new_live"
        [ -n "$gone" ] && while read -r g; do
            [ -n "$g" ] && echo "    ➖ documented but NOT live:  $g"
        done <<< "$gone"
    fi
    echo ""
done

if [ "$drift" -eq 1 ]; then
    echo "==> Inventory drift detected — update .github/instructions/cloudsql-connections.instructions.md."
else
    echo "==> Inventory is up to date."
fi
exit 0
