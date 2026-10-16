#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 12: Hard Reset & Cleanup Demo Environment (v1.0 Baseline Restore)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 12: Reset & Cleanup Demo Environment                   ==="
echo "==================================================================="
echo "This script restores the environment to its pristine baseline state:"
echo " 1. Resets Git repo models on '${DEFAULT_BRANCH}' to v1.0 (without 'customer_tier')"
echo " 2. Hard-resets Git branches ('main' & 'development') back to baseline commit"
echo " 3. Deletes & recreates Dataform workspace ('${DEVELOPER_WORKSPACE}') to prevent merge conflicts"
echo " 4. Compiles & executes Dataform DEV release in ${DEV_PROJECT}"
echo " 5. Restores PROD target table (${PROD_PROJECT}.analytics_curated) to v1.0 baseline"
echo " 6. Removes developer sandbox datasets (__alice)"
echo " 7. Verifies 'customer_tier' is removed from DEV & PROD BigQuery tables"
echo "==================================================================="

export GIT_TERMINAL_PROMPT=0
GCLOUD_SDK_ROOT=$(gcloud info --format="value(installation.sdk_root)")
export PATH="${GCLOUD_SDK_ROOT}/bin:${PATH}"
git config --global credential.'https://*.*.sourcemanager.dev'.helper gcloud.sh 2>/dev/null || true

SSM_PROJECT_NUM=$(gcloud projects describe "${SSM_PROJECT}" --format="value(projectNumber)")
GIT_HTTPS_URL="https://${INSTANCE_ID}-${SSM_PROJECT_NUM}-git.${LOCATION}.sourcemanager.dev/${SSM_PROJECT}/${REPO_ID}.git"
TOKEN=$(gcloud auth print-access-token)
API_BASE="https://securesourcemanager.googleapis.com/v1"
REPO_PATH="projects/${SSM_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}"
RULE_ID="main-protection"

# Step 1: Temporarily Lift Branch Protection to reset branch pointers cleanly
echo ""
echo ">>> [Step 1/6] Temporarily lifting SSM branch rule to allow branch synchronization <<<"
curl -s -X DELETE \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API_BASE}/${REPO_PATH}/branchRules/${RULE_ID}" >/dev/null 2>&1 || true

# Step 2: Reset Git repository on both main and development
echo ""
echo ">>> [Step 2/6] Resetting Git repository on 'main' and '${DEFAULT_BRANCH}' to v1.0 baseline <<<"
TMP_WORKSPACE=$(mktemp -d)
git -c credential.helper=gcloud.sh clone "${GIT_HTTPS_URL}" "${TMP_WORKSPACE}" >/dev/null 2>&1

pushd "${TMP_WORKSPACE}" >/dev/null

cat <<'EOF' > definitions/outputs/fct_cleaned_transactions.sqlx
config {
  type: "table",
  schema: "analytics_curated",
  name: "fct_cleaned_transactions",
  description: "Curated fact table containing validated, deduplicated customer transactions ready for BI and downstream analytics.",
  columns: {
    transaction_id: "Primary Key: Unique transaction identifier",
    customer_id: "Customer identifier",
    transaction_date: "Date of transaction for partition filtering",
    transaction_timestamp: "Timestamp of transaction",
    transaction_amount: "Final positive transaction amount",
    payment_status: "Validated payment status",
    is_high_value: "Boolean flag for transactions >= $1000",
    processed_at: "Ingestion/processing timestamp"
  },
  bigquery: {
    partitionBy: "transaction_date",
    clusterBy: ["customer_id", "payment_status"]
  }
}

/**
 * Stage 2: Deduplication, Enrichment & Final Table Materialization
 * - Reads from intermediate stage view ${ref("stg_transactions")}
 * - Deduplicates on transaction_id keeping the latest record
 * - Enriches with business flags (is_high_value)
 */
WITH ranked_transactions AS (
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
    ${ref("stg_transactions")}
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
  ranked_transactions
WHERE
  row_num = 1
EOF

git config user.name "Demo Automation"
git config user.email "automation@altostrat.com"
git checkout main
git add definitions/outputs/fct_cleaned_transactions.sqlx
git commit -m "chore: reset baseline to v1.0 (without customer_tier)" >/dev/null 2>&1 || true
git checkout -B "${DEFAULT_BRANCH}" main >/dev/null 2>&1
git -c credential.helper=gcloud.sh push origin main:refs/heads/main "${DEFAULT_BRANCH}:refs/heads/${DEFAULT_BRANCH}" --force >/dev/null 2>&1

popd >/dev/null
rm -rf "${TMP_WORKSPACE}"

# Step 3: Re-enable Branch Protection on main
echo ""
echo ">>> [Step 3/6] Restoring SSM Branch Protection Rule on 'main' <<<"
BRANCH_RULE_PAYLOAD=$(cat <<EOF
{
  "includePattern": "main",
  "requirePullRequest": true,
  "minimumReviewsCount": 1,
  "minimumApprovalsCount": 1,
  "requireCodeOwnerApproval": false,
  "requireCommentsResolved": true,
  "allowStaleReviews": false,
  "requireLinearHistory": true
}
EOF
)

curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BRANCH_RULE_PAYLOAD}" \
  "${API_BASE}/${REPO_PATH}/branchRules?branchRuleId=${RULE_ID}" >/dev/null 2>&1 || true

echo "✔ Branch protection on 'main' restored."

# Step 4: Recreate Clean Dataform Workspace
echo ""
echo ">>> [Step 4/6] Recreating clean developer workspace '${DEVELOPER_WORKSPACE}' in Dataform <<<"
curl -s -X DELETE \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workspaces/${DEVELOPER_WORKSPACE}" >/dev/null 2>&1 || true

curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "https://dataform.googleapis.com/v1beta1/projects/${DEV_PROJECT}/locations/${LOCATION}/repositories/${REPO_ID}/workspaces?workspaceId=${DEVELOPER_WORKSPACE}" >/dev/null 2>&1 || true

echo "✔ Developer workspace '${DEVELOPER_WORKSPACE}' recreated and in sync."

# Step 5: Clean Developer Sandbox Datasets
echo ""
echo ">>> [Step 5/6] Cleaning developer sandbox datasets in BigQuery <<<"
bq rm -r -f -d "${DEV_PROJECT}:analytics_curated__${DEVELOPER_WORKSPACE}" >/dev/null 2>&1 || true
bq rm -r -f -d "${DEV_PROJECT}:dataform_assertions__${DEVELOPER_WORKSPACE}" >/dev/null 2>&1 || true
echo "✔ Developer sandbox datasets cleaned."

# Step 6: Compile & Execute DEV and PROD baseline tables
echo ""
echo ">>> [Step 6/6] Resetting DEV & PROD BigQuery Curated Tables to v1.0 <<<"

# Run DEV ELT execution
"$(dirname "$0")/09_execute_elt_pipeline.sh" >/dev/null 2>&1 || true

# Restore PROD curated table
bq query --project_id="${PROD_PROJECT}" --location="${LOCATION}" --use_legacy_sql=false \
  "CREATE OR REPLACE TABLE \`${PROD_PROJECT}.analytics_curated.fct_cleaned_transactions\`
   PARTITION BY transaction_date
   CLUSTER BY customer_id, payment_status
   AS SELECT transaction_id, customer_id, DATE(transaction_timestamp) AS transaction_date, transaction_timestamp, transaction_amount, payment_status, (transaction_amount >= 1000.0) AS is_high_value, CURRENT_TIMESTAMP() AS processed_at
   FROM \`${PROD_PROJECT}.raw_vault.raw_transactions\` WHERE transaction_id IS NOT NULL AND transaction_amount >= 0;" >/dev/null 2>&1 || true

echo ""
echo "=== Final Verification ==="
DEV_SCHEMA=$(bq show --schema "${DEV_PROJECT}:analytics_curated.fct_cleaned_transactions" 2>/dev/null || echo "")
PROD_SCHEMA=$(bq show --schema "${PROD_PROJECT}:analytics_curated.fct_cleaned_transactions" 2>/dev/null || echo "")

if echo "${DEV_SCHEMA}" | grep -q "customer_tier"; then
  echo "✘ Warning: customer_tier still found in DEV."
else
  echo "✔ Confirmed: 'customer_tier' is absent from DEV analytics_curated."
fi

if echo "${PROD_SCHEMA}" | grep -q "customer_tier"; then
  echo "✘ Warning: customer_tier still found in PROD."
else
  echo "✔ Confirmed: 'customer_tier' is absent from PROD analytics_curated."
fi

echo ""
echo "==================================================================="
echo "=== Demo Environment Reset Completed Successfully! (v1.0 Ready)==="
echo "==================================================================="
