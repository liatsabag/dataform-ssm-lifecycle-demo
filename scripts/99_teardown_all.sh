#!/usr/bin/env bash
# =============================================================================
# 99_teardown_all.sh
# Complete cleanup / teardown of all demo resources across the 3 projects:
# - Dataform repositories and workspaces in DEV
# - Developer Connect connections in DEV
# - BigQuery datasets across DEV and PROD
# - Service accounts in DEV
# - Secure Source Manager repository in SSM
# - Optional: Pass '--delete-projects' to delete the GCP projects themselves
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

DELETE_PROJECTS_FLAG="${1:-}"

echo "==================================================================="
echo "=== COMPLETE DEMO TEARDOWN & RESOURCE CLEANUP                   ==="
echo "==================================================================="
echo "Target Projects:"
echo "  • DEV : ${DEV_PROJECT:-<None>}"
echo "  • PROD: ${PROD_PROJECT:-<None>}"
echo "  • SSM : ${SSM_PROJECT:-<None>}"
echo "==================================================================="

# 1. Delete Dataform Repository in DEV
if [ -n "${DEV_PROJECT:-}" ]; then
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

  # 3. Delete BigQuery Datasets in DEV
  echo "3. Deleting BigQuery datasets in ${DEV_PROJECT}..."
  bq rm -r -f -d "${DEV_PROJECT}:${TARGET_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${DEV_PROJECT}:${ASSERTION_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${DEV_PROJECT}:${TARGET_DATASET}__${DEVELOPER_WORKSPACE}" 2>/dev/null || true

  # 4. Delete Service Account in DEV
  echo "4. Deleting executor service account in ${DEV_PROJECT}..."
  gcloud iam service-accounts delete "${EXECUTOR_SA}" \
    --project="${DEV_PROJECT}" \
    --quiet 2>/dev/null || true
fi

# 5. Delete BigQuery Datasets in PROD
if [ -n "${PROD_PROJECT:-}" ]; then
  echo "5. Deleting BigQuery datasets in ${PROD_PROJECT}..."
  bq rm -r -f -d "${PROD_PROJECT}:${SOURCE_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${PROD_PROJECT}:${TARGET_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${PROD_PROJECT}:${ASSERTION_DATASET}" 2>/dev/null || true
fi

# 6. Delete Secure Source Manager Repository in SSM
if [ -n "${SSM_PROJECT:-}" ]; then
  echo "6. Deleting Secure Source Manager repository in ${SSM_PROJECT}..."
  gcloud source-manager repos delete "${REPO_ID}" \
    --region="${LOCATION}" \
    --project="${SSM_PROJECT}" \
    --quiet 2>/dev/null || true
fi

# Optional: Delete GCP Projects
if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ]; then
  echo ""
  echo "7. Deleting GCP Projects..."
  [ -n "${DEV_PROJECT:-}" ] && gcloud projects delete "${DEV_PROJECT}" --quiet 2>/dev/null || true
  [ -n "${PROD_PROJECT:-}" ] && gcloud projects delete "${PROD_PROJECT}" --quiet 2>/dev/null || true
  [ -n "${SSM_PROJECT:-}" ] && gcloud projects delete "${SSM_PROJECT}" --quiet 2>/dev/null || true

  # Reset project IDs in config.env
  python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()
content = re.sub(r'^export DEV_PROJECT=.*', 'export DEV_PROJECT=\"\"', content, flags=re.MULTILINE)
content = re.sub(r'^export PROD_PROJECT=.*', 'export PROD_PROJECT=\"\"', content, flags=re.MULTILINE)
content = re.sub(r'^export SSM_PROJECT=.*', 'export SSM_PROJECT=\"\"', content, flags=re.MULTILINE)
with open(f, 'w') as fp:
    fp.write(content)
"
  echo "✔ Projects deleted and config.env reset."
  echo "Running './scripts/00_deploy_all.sh' will now provision brand new projects from scratch using your project names!"
else
  echo ""
  echo "✔ All demo datasets, repositories, connections, and service accounts have been wiped."
  echo "You can now run './scripts/00_deploy_all.sh' for a fresh deployment test!"
fi
