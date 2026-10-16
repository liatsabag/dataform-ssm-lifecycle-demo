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

# Step 2: Materialize Tier 2 Staging View & Tier 3 Curated Fact Table in DEV
echo ""
echo ">>> [Step 2/5] Materializing DEV Pipeline (${DEV_PROJECT}.${TARGET_DATASET}) <<<"
STG_DEV_SQL="CREATE OR REPLACE VIEW \`${DEV_PROJECT}.${TARGET_DATASET}.stg_transactions\`
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
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${STG_DEV_SQL}"

echo "✔ Created/updated view ${DEV_PROJECT}.${TARGET_DATASET}.stg_transactions"

FCT_DEV_SQL="CREATE OR REPLACE TABLE \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
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
    \`${DEV_PROJECT}.${TARGET_DATASET}.stg_transactions\`
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
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${FCT_DEV_SQL}"

echo "✔ Materialized curated table ${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions"

# Step 3: Materialize Tier 2 Staging View & Tier 3 Curated Fact Table in PROD
echo ""
echo ">>> [Step 3/5] Materializing PROD Baseline Pipeline (${PROD_PROJECT}.${TARGET_DATASET}) <<<"
STG_PROD_SQL="CREATE OR REPLACE VIEW \`${PROD_PROJECT}.${TARGET_DATASET}.stg_transactions\`
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
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${STG_PROD_SQL}"

echo "✔ Created/updated view ${PROD_PROJECT}.${TARGET_DATASET}.stg_transactions"

FCT_PROD_SQL="CREATE OR REPLACE TABLE \`${PROD_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
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
    \`${PROD_PROJECT}.${TARGET_DATASET}.stg_transactions\`
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
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  "${FCT_PROD_SQL}"

echo "✔ Materialized curated table ${PROD_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions"

# Step 4: Run Data Quality Assertions on DEV
echo ""
echo ">>> [Step 4/5] Executing Data Quality Assertions on DEV (${DEV_PROJECT}) <<<"

# Assertion 1: Unique Transaction ID
echo "Checking Assertion: assert_unique_transaction_id in ${DEV_PROJECT}..."
ASSERT_UNIQUE_SQL="SELECT
  transaction_id,
  COUNT(*) AS occurrences
FROM
  \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
GROUP BY
  transaction_id
HAVING
  occurrences > 1
  OR transaction_id IS NULL;"

VIOLATIONS_1=$(bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${ASSERT_UNIQUE_SQL}")

if [ "${VIOLATIONS_1}" != "[]" ]; then
  echo "✘ ASSERTION FAILED: Found duplicate or null transaction IDs:"
  echo "${VIOLATIONS_1}"
  exit 1
fi
echo "✔ PASS: assert_unique_transaction_id in DEV (0 violations)"

# Assertion 2: Positive Amounts
echo "Checking Assertion: assert_positive_amounts in ${DEV_PROJECT}..."
ASSERT_AMOUNT_SQL="SELECT
  transaction_id,
  transaction_amount
FROM
  \`${DEV_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`
WHERE
  transaction_amount < 0
  OR transaction_amount IS NULL;"

VIOLATIONS_2=$(bq query \
  --project_id="${DEV_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=json \
  "${ASSERT_AMOUNT_SQL}")

if [ "${VIOLATIONS_2}" != "[]" ]; then
  echo "✘ ASSERTION FAILED: Found negative or null transaction amounts:"
  echo "${VIOLATIONS_2}"
  exit 1
fi
echo "✔ PASS: assert_positive_amounts in DEV (0 violations)"

# Step 5: Verify PROD Baseline Records
echo ""
echo ">>> [Step 5/5] Verifying PROD Curated Table Record Count <<<"
PROD_COUNT=$(bq query \
  --project_id="${PROD_PROJECT}" \
  --location="${LOCATION}" \
  --use_legacy_sql=false \
  --format=csv \
  "SELECT COUNT(*) AS total_curated_records FROM \`${PROD_PROJECT}.${TARGET_DATASET}.fct_cleaned_transactions\`" | tail -n 1)

echo "✔ PROD curated fact table contains ${PROD_COUNT} validated records."

echo ""
echo "==================================================================="
echo "=== Step 9 ELT Pipeline Baseline Materialization Complete       ==="
echo "==================================================================="
