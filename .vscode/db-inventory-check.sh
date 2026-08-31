#!/usr/bin/env bash
# Read-only-toward-GCP DB inventory drift check — runs at VS Code startup (folderOpen task).
# Confirms the live CloudSQL + AlloyDB instance inventory across dev/qa/stage
# still matches what's documented in the connections instructions file. Any
# instance that's no longer live gets pruned from the doc automatically; new
# live instances are only reported (adding them needs human-supplied details
# like region/tier/port).
#
# STRICTLY READ-ONLY TOWARD GCP: only *list* calls. No describe, no patch/delete,
# no SQL. The only write is to the local markdown doc. Always exits 0 (non-blocking).
#
# Override the project set with DB_INV_PROJECTS (space-separated).
# Set DB_INV_NO_PRUNE=1 to fall back to report-only (no doc edits).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$SCRIPT_DIR/../.github/instructions/cloudsql-connections.instructions.md"
PRUNER="$SCRIPT_DIR/db-inventory-prune.py"
PROJECTS="${DB_INV_PROJECTS:-vz-inscape-portfolio-dev vz-inscape-portfolio-qa vz-inscape-portfolio-stage}"

# ---- preflight -------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
    echo "[SKIP] gcloud not found on PATH — skipping DB inventory check."
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 not found on PATH — skipping DB inventory check."
    exit 0
fi
if [ ! -f "$DOC" ]; then
    echo "[SKIP] connections doc not found at $DOC — skipping DB inventory check."
    exit 0
fi
if [ ! -f "$PRUNER" ]; then
    echo "[SKIP] $PRUNER not found — skipping DB inventory check."
    exit 0
fi
if ! gcloud auth print-access-token >/dev/null 2>&1; then
    echo "[SKIP] gcloud not authenticated — run 'Cloud Auth Login' first. Skipping DB inventory check."
    exit 0
fi

VERIFIED=$(grep -oE 'Inventory last verified: [0-9-]+' "$DOC" | head -1 | sed 's/Inventory last verified: //')
echo "==> DB Inventory Drift Check"
echo "    Source of truth: .github/instructions/cloudsql-connections.instructions.md${VERIFIED:+ (last verified $VERIFIED)}"
echo "    Projects: $PROJECTS"
[ "${DB_INV_NO_PRUNE:-0}" = "1" ] && echo "    Mode: report-only (DB_INV_NO_PRUNE=1, no doc edits)"
echo ""

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

LIVE_TSV="$(mktemp)"
trap 'rm -f "$LIVE_TSV"' EXIT

for project in $PROJECTS; do
    if ! gcloud projects describe "$project" >/dev/null 2>&1; then
        printf '%s\t__INACCESSIBLE__\n' "$project" >> "$LIVE_TSV"
        continue
    fi
    live "$project" >> "$LIVE_TSV"
done

if [ "${DB_INV_NO_PRUNE:-0}" = "1" ]; then
    python3 "$PRUNER" --report-only "$DOC" "$LIVE_TSV" $PROJECTS
else
    python3 "$PRUNER" "$DOC" "$LIVE_TSV" $PROJECTS
fi
exit 0
