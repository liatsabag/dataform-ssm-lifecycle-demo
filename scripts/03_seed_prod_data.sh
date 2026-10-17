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
MAX_ATTEMPTS=3
ATTEMPT=1
SEEDED=false

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
  if bq query \
    --project_id="${PROD_PROJECT}" \
    --location="${LOCATION}" \
    --use_legacy_sql=false \
    < "${SCRIPT_DIR}/seed_raw_transactions.sql"; then
    SEEDED=true
    break
  else
    echo "⚠️ Query execution encountered transient error (attempt ${ATTEMPT}/${MAX_ATTEMPTS}). Retrying in 3s..."
    ATTEMPT=$((ATTEMPT + 1))
    sleep 3
  fi
done

if [ "${SEEDED}" != "true" ]; then
  echo "✘ Failed to seed raw data into ${PROD_PROJECT}.raw_vault.raw_transactions after ${MAX_ATTEMPTS} attempts."
  exit 1
fi

echo ""
echo "=== Verifying Seeded Table Count ==="
RECORD_COUNT=$(bq query \
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=csv \
  "SELECT COUNT(*) AS total_raw_records FROM \`${PROD_PROJECT}.raw_vault.raw_transactions\`" | sed 1d | tr -d '[:space:]')

echo "Total raw records in table: ${RECORD_COUNT}"
if [ "${RECORD_COUNT}" -eq 14 ]; then
  echo "✔ Raw source data seeded successfully (14/14 records verified)."
else
  echo "⚠️ Expected 14 records but found ${RECORD_COUNT}."
fi
