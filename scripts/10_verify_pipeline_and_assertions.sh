#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 10: 3-Tier ELT Pipeline & Anti-Hijacking Verification Suite
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 10: 3-Tier ELT Pipeline Verification & Assertions      ==="
echo "==================================================================="
echo "Target Project : ${TARGET_PROJECT}"
echo "Target Dataset : ${TARGET_DATASET}"
echo "PROD Project   : ${PROD_PROJECT}"
echo "Location       : ${LOCATION}"
echo "==================================================================="

PASSED_TESTS=0
TOTAL_TESTS=6

# Test 1: Dataform Compilation & Anti-Hijacking Resolution
echo ""
echo ">>> [Test 1/6] Anti-Hijacking & Cross-Project Source Resolution Test <<<"
COMPILE_JSON=$(cd "$(dirname "$0")/.." && npx -y @dataform/cli compile --json 2>/dev/null)

SOURCE_DB=$(echo "${COMPILE_JSON}" | grep -o "\"database\": \"${PROD_PROJECT}\"" | head -n 1 || true)
SOURCE_SCHEMA=$(echo "${COMPILE_JSON}" | grep -o '"schema": "raw_vault"' | head -n 1 || true)
TARGET_DB=$(echo "${COMPILE_JSON}" | grep -o "\"database\": \"${DEV_PROJECT}\"" | head -n 1 || true)

if [ -n "${SOURCE_DB}" ] && [ -n "${SOURCE_SCHEMA}" ] && [ -n "${TARGET_DB}" ]; then
  echo "✔ PASS: DAG correctly resolves upstream source to ${PROD_PROJECT}:raw_vault and target to ${DEV_PROJECT}."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Source anti-hijacking resolution failed in compiled DAG."
fi

# Test 2: Intermediate View Data Cleansing (DEV)
echo ""
echo ">>> [Test 2/6] DEV Intermediate Staging View Cleansing & Filtering Test <<<"
CLEANSED_TEST_SQL="SELECT
  COUNTIF(transaction_amount < 0) AS negative_amounts_count,
  COUNTIF(transaction_id IS NULL OR TRIM(transaction_id) = '') AS blank_ids_count,
  COUNTIF(payment_status != UPPER(payment_status)) AS unnormalized_status_count
FROM \`${DEV_PROJECT}.${TARGET_DATASET}.stg_transactions\`;"

CLEANSED_RESULTS=$(bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${CLEANSED_TEST_SQL}")

PYTHON_CHECK_2=$(python3 -c "
import sys, json
data = json.loads('''${CLEANSED_RESULTS}''')[0]
neg = int(data.get('negative_amounts_count', 1))
blank = int(data.get('blank_ids_count', 1))
unnorm = int(data.get('unnormalized_status_count', 1))
if neg == 0 and blank == 0 and unnorm == 0:
    print('PASS')
else:
    print(f'FAIL neg={neg} blank={blank} unnorm={unnorm}')
")

if [ "${PYTHON_CHECK_2}" = "PASS" ]; then
  echo "✔ PASS: Intermediate view filtered invalid records and normalized data types correctly."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Intermediate view contains uncleaned records (${PYTHON_CHECK_2})."
fi

# Test 3: Deduplication & Fact Table Business Logic (DEV)
echo ""
echo ">>> [Test 3/6] DEV Fact Table Deduplication & Business Logic Test <<<"
DEDUP_TEST_SQL="SELECT
  COUNTIF(transaction_id = 'TXN_1004') AS txn_1004_count,
  MAX(IF(transaction_id = 'TXN_1004', payment_status, NULL)) AS txn_1004_status,
  COUNTIF(transaction_id = 'TXN_1005') AS txn_1005_count,
  MAX(IF(transaction_id = 'TXN_1005', payment_status, NULL)) AS txn_1005_status,
  COUNTIF(is_high_value = TRUE) AS high_value_count
FROM \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`;"

DEDUP_RESULTS=$(bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${DEDUP_TEST_SQL}")

PYTHON_CHECK_3=$(python3 -c "
import sys, json
data = json.loads('''${DEDUP_RESULTS}''')[0]
c1004 = int(data.get('txn_1004_count', 0))
s1004 = data.get('txn_1004_status', '')
c1005 = int(data.get('txn_1005_count', 0))
s1005 = data.get('txn_1005_status', '')
high = int(data.get('high_value_count', 0))

if c1004 == 1 and s1004 == 'COMPLETED' and c1005 == 1 and s1005 == 'COMPLETED' and high == 3:
    print('PASS')
else:
    print(f'FAIL c1004={c1004}({s1004}) c1005={c1005}({s1005}) high={high}')
")

if [ "${PYTHON_CHECK_3}" = "PASS" ]; then
  echo "✔ PASS: Deduplication retained latest state per ID and is_high_value flag correctly classified 3 transactions."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Deduplication or business logic check failed (${PYTHON_CHECK_3})."
fi

# Test 4: BigQuery Table Partitioning & Clustering Verification
echo ""
echo ">>> [Test 4/6] DEV Physical Optimization (Partitioning & Clustering) Verification <<<"
TABLE_INFO=$(bq show --format=prettyjson "${DEV_PROJECT}:${TARGET_DATASET}.fct_cleaned_transactions")

PARTITION_FIELD=$(echo "${TABLE_INFO}" | grep -o '"field": "transaction_date"' || true)
CLUSTER_CUSTOMER=$(echo "${TABLE_INFO}" | grep -o '"customer_id"' || true)
CLUSTER_STATUS=$(echo "${TABLE_INFO}" | grep -o '"payment_status"' || true)

if [ -n "${PARTITION_FIELD}" ] && [ -n "${CLUSTER_CUSTOMER}" ] && [ -n "${CLUSTER_STATUS}" ]; then
  echo "✔ PASS: Table fct_cleaned_transactions is partitioned by transaction_date and clustered by [customer_id, payment_status]."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Table partitioning or clustering metadata check failed."
fi

# Test 5: Automated Data Quality Assertions (DEV)
echo ""
echo ">>> [Test 5/6] DEV Automated Data Quality Assertions Check <<<"
ASSERT_FAILURES=$(bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "SELECT transaction_id FROM \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\` GROUP BY transaction_id HAVING COUNT(*) > 1 OR transaction_id IS NULL UNION ALL SELECT transaction_id FROM \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\` WHERE transaction_amount < 0 OR transaction_amount IS NULL;")

if [ "${ASSERT_FAILURES}" = "[]" ]; then
  echo "✔ PASS: All data quality assertions passed with zero violations in DEV."
  PASSED_TESTS=$((PASSED_TESTS + 1))
else
  echo "✘ FAIL: Assertions found data quality violations: ${ASSERT_FAILURES}"
fi

# Test 6: PROD Baseline Table & Schema Verification
echo ""
echo ">>> [Test 6/6] PROD Baseline Curated Table & Schema Verification <<<"
PROD_SCHEMA=$(bq show --schema "${PROD_PROJECT}:${TARGET_DATASET}.fct_cleaned_transactions" 2>/dev/null || echo "NOT_FOUND")

if [ "${PROD_SCHEMA}" = "NOT_FOUND" ]; then
  echo "✘ FAIL: PROD curated table ${PROD_PROJECT}:${TARGET_DATASET}.fct_cleaned_transactions does not exist."
elif echo "${PROD_SCHEMA}" | grep -q "customer_tier"; then
  echo "✘ FAIL: PROD curated table contains 'customer_tier' (baseline should be v1.0 without this feature)."
else
  PROD_RECORD_COUNT=$(bq query \
    --project_id="${PROD_PROJECT}" \
    --location="${LOCATION}" \
    --use_legacy_sql=false \
    "SELECT COUNT(*) AS total_records FROM \`${PROD_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`" \
    --format=csv | tail -n 1)
  
  if [ "${PROD_RECORD_COUNT}" -gt 0 ]; then
    echo "✔ PASS: PROD baseline table verified (${PROD_RECORD_COUNT} records, v1.0 schema without 'customer_tier')."
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    echo "✘ FAIL: PROD curated table exists but is empty (0 records)."
  fi
fi

echo ""
echo "==================================================================="
echo "=== Step 10 Verification Result: ${PASSED_TESTS}/${TOTAL_TESTS} Tests Passed ==="
echo "==================================================================="

if [ "${PASSED_TESTS}" -eq "${TOTAL_TESTS}" ]; then
  echo "🎉 3-TIER ELT PIPELINE VERIFICATION COMPLETE: ALL TESTS PASSED!"
  exit 0
else
  echo "❌ SOME TESTS FAILED. Please review output above."
  exit 1
fi
