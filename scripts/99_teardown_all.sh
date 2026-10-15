#!/usr/bin/env bash
# =============================================================================
# 99_teardown_all.sh
# Complete cleanup / teardown of all demo resources across DEV, PROD, and SSM:
# - Dataform repositories and workspaces in DEV
# - Developer Connect connections in DEV
# - BigQuery datasets across DEV and PROD (including developer sandboxes)
# - Service accounts in DEV
# - Secure Source Manager repository in SSM
# - Optional: Pass '--delete-projects' to delete the GCP projects themselves.
#
# NOTE: If project IDs are not recorded in config.env (e.g. after a failed run),
# this script dynamically searches GCP for any active projects matching the
# configured project display names (DEV_PROJECT_NAME, PROD_PROJECT_NAME, SSM_PROJECT_NAME).
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

# Helper function to find active project IDs for a given name/var
discover_projects() {
  local configured_id="$1"
  local project_name="$2"
  local project_ids=()
  
  if [ -n "${configured_id}" ]; then
    local state
    state=$(gcloud projects describe "${configured_id}" --format="value(lifecycleState)" 2>/dev/null || echo "NOT_FOUND")
    if [ "${state}" = "ACTIVE" ]; then
      project_ids+=("${configured_id}")
    fi
  fi
  
  if [ -n "${project_name}" ]; then
    while IFS= read -r pid; do
      if [ -n "${pid}" ]; then
        # Avoid duplicate entries
        if [[ ! " ${project_ids[*]:-} " =~ " ${pid} " ]]; then
          project_ids+=("${pid}")
        fi
      fi
    done < <(gcloud projects list --filter="name:${project_name} AND lifecycleState:ACTIVE" --format="value(projectId)" 2>/dev/null || true)
  fi
  
  echo "${project_ids[*]:-}"
}

echo ">>> Discovering active demo projects in GCP..."
DEV_PIDS=($(discover_projects "${DEV_PROJECT:-}" "${DEV_PROJECT_NAME:-df-demo-dev}"))
PROD_PIDS=($(discover_projects "${PROD_PROJECT:-}" "${PROD_PROJECT_NAME:-df-demo-prod}"))
SSM_PIDS=($(discover_projects "${SSM_PROJECT:-}" "${SSM_PROJECT_NAME:-df-demo-ssm}"))

echo "==================================================================="
echo "=== COMPLETE DEMO TEARDOWN & RESOURCE CLEANUP                   ==="
echo "==================================================================="
echo "Discovered Target Projects:"
echo "  • DEV : ${DEV_PIDS[*]:-<None found>}"
echo "  • PROD: ${PROD_PIDS[*]:-<None found>}"
echo "  • SSM : ${SSM_PIDS[*]:-<None found>}"
echo "==================================================================="

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

# 1. Clean DEV Projects
for dev_p in "${DEV_PIDS[@]:-}"; do
  [ -z "${dev_p}" ] && continue
  echo ">>> Cleaning DEV Project: ${dev_p}..."

  # 1.1 Delete Dataform Repository
  echo "  1. Deleting Dataform repository '${REPO_ID}' in ${dev_p}..."
  if [ -n "${TOKEN:-}" ]; then
    curl -s -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "https://dataform.googleapis.com/v1beta1/projects/${dev_p}/locations/${LOCATION}/repositories/${REPO_ID}?force=true" >/dev/null 2>&1 || true
  fi

  # 1.2 Delete Developer Connect Connection
  echo "  2. Deleting Developer Connect connection '${CONN_ID}' in ${dev_p}..."
  gcloud developer-connect connections delete "${CONN_ID}" \
    --location="${LOCATION}" \
    --project="${dev_p}" \
    --quiet 2>/dev/null || true

  # 1.3 Delete BigQuery Datasets
  echo "  3. Deleting BigQuery datasets in ${dev_p}..."
  bq rm -r -f -d "${dev_p}:${TARGET_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${dev_p}:${ASSERTION_DATASET}" 2>/dev/null || true
  if [ -n "${DEVELOPER_WORKSPACE:-}" ]; then
    bq rm -r -f -d "${dev_p}:${TARGET_DATASET}_${DEVELOPER_WORKSPACE}" 2>/dev/null || true
    bq rm -r -f -d "${dev_p}:${ASSERTION_DATASET}_${DEVELOPER_WORKSPACE}" 2>/dev/null || true
    bq rm -r -f -d "${dev_p}:${TARGET_DATASET}__${DEVELOPER_WORKSPACE}" 2>/dev/null || true
  fi

  # 1.4 Delete Executor Service Account
  echo "  4. Deleting executor service account in ${dev_p}..."
  exec_sa="dataform-executor@${dev_p}.iam.gserviceaccount.com"
  gcloud iam service-accounts delete "${exec_sa}" \
    --project="${dev_p}" \
    --quiet 2>/dev/null || true

  # 1.5 Delete Project if requested
  if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ]; then
    echo "  5. Deleting project ${dev_p}..."
    gcloud projects delete "${dev_p}" --quiet 2>/dev/null || true
  fi
done

# 2. Clean PROD Projects
for prod_p in "${PROD_PIDS[@]:-}"; do
  [ -z "${prod_p}" ] && continue
  echo ">>> Cleaning PROD Project: ${prod_p}..."

  # 2.1 Delete BigQuery Datasets
  echo "  1. Deleting BigQuery datasets in ${prod_p}..."
  bq rm -r -f -d "${prod_p}:${SOURCE_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${prod_p}:${TARGET_DATASET}" 2>/dev/null || true
  bq rm -r -f -d "${prod_p}:${ASSERTION_DATASET}" 2>/dev/null || true

  # 2.2 Delete Project if requested
  if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ]; then
    echo "  2. Deleting project ${prod_p}..."
    gcloud projects delete "${prod_p}" --quiet 2>/dev/null || true
  fi
done

# 3. Clean SSM Projects
for ssm_p in "${SSM_PIDS[@]:-}"; do
  [ -z "${ssm_p}" ] && continue
  echo ">>> Cleaning SSM Project: ${ssm_p}..."

  # 3.1 Delete SSM Repository
  echo "  1. Deleting Secure Source Manager repository in ${ssm_p}..."
  gcloud source-manager repos delete "${REPO_ID}" \
    --region="${LOCATION}" \
    --project="${ssm_p}" \
    --quiet 2>/dev/null || true

  # 3.2 Delete Project if requested
  if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ]; then
    echo "  2. Deleting project ${ssm_p}..."
    gcloud projects delete "${ssm_p}" --quiet 2>/dev/null || true
  fi
done

# 4. Reset config.env and workflow_settings.yaml
echo "4. Resetting configuration files..."
python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()

# If deleting projects or resetting config, clear resolved project IDs and billing
if '${DELETE_PROJECTS_FLAG}' == '--delete-projects':
    content = re.sub(r'^export DEV_PROJECT=.*', 'export DEV_PROJECT=\"\"', content, flags=re.MULTILINE)
    content = re.sub(r'^export PROD_PROJECT=.*', 'export PROD_PROJECT=\"\"', content, flags=re.MULTILINE)
    content = re.sub(r'^export SSM_PROJECT=.*', 'export SSM_PROJECT=\"\"', content, flags=re.MULTILINE)
    content = re.sub(r'^export BILLING_ID=.*', 'export BILLING_ID=\"\"', content, flags=re.MULTILINE)

# Always remove runtime-generated exports
content = re.sub(r'# Auto-resolved Runtime Configuration.*', '', content, flags=re.DOTALL)
content = re.sub(r'\n{3,}', '\n\n', content)
with open(f, 'w') as fp:
    fp.write(content.strip() + '\n')
"

WORKFLOW_SETTINGS="${SCRIPT_DIR}/../workflow_settings.yaml"
if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ] && [ -f "${WORKFLOW_SETTINGS}" ]; then
  python3 -c "
import re
f = '${WORKFLOW_SETTINGS}'
with open(f, 'r') as fp:
    content = fp.read()
content = re.sub(r'defaultProject:\s*.*', 'defaultProject: df-demo-dev', content)
content = re.sub(r'source_project:\s*.*', 'source_project: df-demo-prod', content)
with open(f, 'w') as fp:
    fp.write(content)
"
fi

echo "==================================================================="
if [ "${DELETE_PROJECTS_FLAG}" = "--delete-projects" ]; then
  echo "✔ Projects deleted and config.env reset to pristine defaults."
  echo "Running './scripts/00_deploy_all.sh' will now provision brand new projects from scratch using your project names!"
else
  echo "✔ All demo datasets, repositories, connections, and service accounts have been wiped."
  echo "✔ Runtime variables cleared from config.env."
  echo "You can now run './scripts/00_deploy_all.sh' for a fresh deployment test!"
fi
echo "==================================================================="
