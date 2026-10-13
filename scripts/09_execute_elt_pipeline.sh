#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 9: 3-Tier Dataform ELT Pipeline Baseline Execution
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 9: 3-Tier Dataform ELT Pipeline Execution              ==="
echo "==================================================================="
echo "Execution Target Project  : ${TARGET_PROJECT}"
echo "Execution Target Dataset  : ${TARGET_DATASET}"
echo "Assertions Dataset        : ${ASSERTION_DATASET}"
echo "Source of Truth Project   : ${PROD_PROJECT}"
echo "Source Dataset (Locked)   : raw_vault"
echo "Location                  : ${LOCATION}"
echo "==================================================================="

# Step 1: Dataform Compilation Verification
echo ""
echo ">>> [Step 1/4] Compiling Dataform Pipeline DAG <<<"
cd "$(dirname "$0")/.."
npx -y @dataform/cli compile

# Step 2: Materialize Tier 2 Staging View
echo ""
echo ">>> [Step 2/4] Materializing Tier 2 Intermediate Staging View (${TARGET_PROJECT}.${TARGET_DATASET}.stg_transactions) <<<"
STG_SQL="CREATE OR REPLACE VIEW \`${TARGET_PROJECT}.${TARGET_DATASET}.stg_transactions\`
OPTIONS(
  description=\"Cleansed and standardized staging transaction view reading from locked PROD raw source.\"
) AS
WITH cleaned AS (
  SELECT
    TRIM(transaction_id) AS transaction_id,
    TRIM(customer_id) AS customer_id,
    SAFE_CAST(transaction_timestamp AS TIMESTAMP) AS transaction_timestamp,
    COALESCE(SAFE_CAST(amount AS NUMERIC), 0.0) AS transaction_amount,
    UPPER(TRIM(COALESCE(status, 'UNKNOWN'))) AS payment_status
  FROM
    \`${PROD_PROJECT}.raw_vault.raw_transactions\`
  WHERE
    transaction_id IS NOT NULL
    AND TRIM(transaction_id) != ''
)
SELECT
  transaction_id,
  customer_id,
  transaction_timestamp,
  transaction_amount,
  payment_status
FROM
  cleaned
WHERE
  transaction_amount >= 0;"

bq query \
  --project_id="${TARGET_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${STG_SQL}"

echo "✔ Successfully created/updated view ${TARGET_PROJECT}.${TARGET_DATASET}.stg_transactions"

# Step 3: Materialize Tier 3 Curated Fact Table
echo ""
echo ">>> [Step 3/4] Materializing Tier 3 Curated Fact Table (${TARGET_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions) <<<"
FCT_SQL="CREATE OR REPLACE TABLE \`${TARGET_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
PARTITION BY transaction_date
CLUSTER BY customer_id, payment_status
OPTIONS(
  description=\"Curated fact table containing validated, deduplicated customer transactions ready for BI and downstream analytics.\"
) AS
WITH deduplicated AS (
  SELECT
    transaction_id,
    customer_id,
    DATE(transaction_timestamp) AS transaction_date,
    transaction_timestamp,
    transaction_amount,
    payment_status,
    ROW_NUMBER() OVER(
      PARTITION BY transaction_id 
      ORDER BY transaction_timestamp DESC
    ) AS row_num
  FROM
    \`${TARGET_PROJECT}.${TARGET_DATASET}.stg_transactions\`
)
SELECT
  transaction_id,
  customer_id,
  transaction_date,
  transaction_timestamp,
  transaction_amount,
  payment_status,
  (transaction_amount >= 1000.0) AS is_high_value,
  CURRENT_TIMESTAMP() AS processed_at
FROM
  deduplicated
WHERE
  row_num = 1;"

bq query \
  --project_id="${TARGET_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${FCT_SQL}"

echo "✔ Successfully materialized table ${TARGET_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions"

# Step 4: Run Data Quality Assertions
echo ""
echo ">>> [Step 4/4] Executing Data Quality Assertions <<<"

# Assertion 1: Unique Transaction ID
echo "Checking Assertion: assert_unique_transaction_id..."
ASSERT_UNIQUE_SQL="SELECT
  transaction_id,
  COUNT(*) AS occurrences
FROM
  \`${TARGET_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
GROUP BY
  transaction_id
HAVING
  occurrences > 1
  OR transaction_id IS NULL;"

VIOLATIONS_1=$(bq query \
  --project_id="${TARGET_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${ASSERT_UNIQUE_SQL}")

if [ "${VIOLATIONS_1}" != "[]" ]; then
  echo "✘ ASSERTION FAILED: Found duplicate or null transaction IDs:"
  echo "${VIOLATIONS_1}"
  exit 1
fi
echo "✔ PASS: assert_unique_transaction_id (0 violations)"

# Assertion 2: Positive Amounts
echo "Checking Assertion: assert_positive_amounts..."
ASSERT_AMOUNT_SQL="SELECT
  transaction_id,
  transaction_amount
FROM
  \`${TARGET_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
WHERE
  transaction_amount < 0
  OR transaction_amount IS NULL;"

VIOLATIONS_2=$(bq query \
  --project_id="${TARGET_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${ASSERT_AMOUNT_SQL}")

if [ "${VIOLATIONS_2}" != "[]" ]; then
  echo "✘ ASSERTION FAILED: Found negative or null transaction amounts:"
  echo "${VIOLATIONS_2}"
  exit 1
fi
echo "✔ PASS: assert_positive_amounts (0 violations)"

echo ""
echo "==================================================================="
echo "=== Step 9 ELT Pipeline Baseline Materialization Complete       ==="
echo "==================================================================="
