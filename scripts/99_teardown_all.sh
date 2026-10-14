#!/usr/bin/env bash
# =============================================================================
# 99_teardown_all.sh
# Complete cleanup / teardown of all demo resources across the 3 projects:
# - Dataform repositories and workspaces in df-demo-dev
# - Developer Connect connections in df-demo-dev
# - BigQuery datasets across df-demo-dev and df-demo-prod
# - Service accounts across df-demo-dev
# - Secure Source Manager repository in df-demo-ssm
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

echo "==================================================================="
echo "=== COMPLETE DEMO TEARDOWN & RESOURCE CLEANUP                   ==="
echo "==================================================================="
echo "Target Projects:"
echo "  • DEV : ${DEV_PROJECT}"
echo "  • PROD: ${PROD_PROJECT}"
echo "  • SSM : ${SSM_PROJECT}"
echo "==================================================================="

# 1. Delete Dataform Repository in DEV
echo "1. Deleting Dataform repository in ${DEV_PROJECT}..."
gcloud dataform repositories delete "${REPO_ID}" \
  --location="${LOCATION}" \
  --project="${DEV_PROJECT}" \
  --quiet 2>/dev/null || true

# 2. Delete Developer Connect Connection in DEV
echo "2. Deleting Developer Connect connection in ${DEV_PROJECT}..."
gcloud developer-connect connections delete "${CONN_ID}" \
  --location="${LOCATION}" \
  --project="${DEV_PROJECT}" \
  --quiet 2>/dev/null || true

# 3. Delete BigQuery Datasets in DEV & PROD
echo "3. Deleting BigQuery datasets in ${DEV_PROJECT} and ${PROD_PROJECT}..."
bq rm -r -f -d "${DEV_PROJECT}:${TARGET_DATASET}" 2>/dev/null || true
bq rm -r -f -d "${DEV_PROJECT}:${ASSERTION_DATASET}" 2>/dev/null || true
bq rm -r -f -d "${DEV_PROJECT}:${TARGET_DATASET}__${DEVELOPER_WORKSPACE}" 2>/dev/null || true

bq rm -r -f -d "${PROD_PROJECT}:${SOURCE_DATASET}" 2>/dev/null || true
bq rm -r -f -d "${PROD_PROJECT}:${TARGET_DATASET}" 2>/dev/null || true
bq rm -r -f -d "${PROD_PROJECT}:${ASSERTION_DATASET}" 2>/dev/null || true

# 4. Delete Service Account in DEV
echo "4. Deleting executor service account in ${DEV_PROJECT}..."
gcloud iam service-accounts delete "${EXECUTOR_SA}" \
  --project="${DEV_PROJECT}" \
  --quiet 2>/dev/null || true

# 5. Delete Secure Source Manager Repository in SSM
echo "5. Deleting Secure Source Manager repository in ${SSM_PROJECT}..."
gcloud source-manager repos delete "${REPO_ID}" \
  --region="${LOCATION}" \
  --project="${SSM_PROJECT}" \
  --quiet 2>/dev/null || true

echo ""
echo "✔ All demo datasets, repositories, connections, and service accounts have been wiped."
echo "You can now run './scripts/00_deploy_all.sh' for a fresh deployment test!"
