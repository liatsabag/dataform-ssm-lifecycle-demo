#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 3: Seeding Raw Source Transactions in PROD raw_vault
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 3: Seeding Raw Source Data into PROD raw_vault         ==="
echo "==================================================================="
echo "PROD Project: ${PROD_PROJECT}"
echo "Location    : ${LOCATION}"
echo "==================================================================="

echo "Seeding raw dirty mock data into ${PROD_PROJECT}.raw_vault.raw_transactions..."
bq query \
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  < "$(dirname "$0")/seed_raw_transactions.sql"

echo ""
echo "=== Verifying Seeded Table Count ==="
bq query \
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "SELECT COUNT(*) AS total_raw_records FROM \`${PROD_PROJECT}.raw_vault.raw_transactions\`"

echo "✔ Raw source data seeded successfully."
