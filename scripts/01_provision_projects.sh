#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 1: Provisioning 3 Projects (DEV, PROD, SSM) & Enabling GCP APIs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Auto-discover Billing Account ID if not explicitly set
if [ -z "${BILLING_ID:-}" ]; then
  echo ">>> Auto-detecting active Billing Account..."
  if [ -n "${SSM_PROJECT:-}" ]; then
    BILLING_ID=$(gcloud billing projects describe "${SSM_PROJECT}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
  fi
  if [ -z "${BILLING_ID:-}" ]; then
    BILLING_ID=$(gcloud billing accounts list --filter="open=true" --format="value(ACCOUNT_ID)" --limit=1 2>/dev/null || true)
  fi
  if [ -n "${BILLING_ID:-}" ]; then
    echo "✔ Auto-detected Billing Account: ${BILLING_ID}"
  fi
fi

# Auto-discover Folder ID if not explicitly set
if [ -z "${FOLDER_ID:-}" ] && [ -n "${SSM_PROJECT:-}" ]; then
  PARENT_TYPE=$(gcloud projects describe "${SSM_PROJECT}" --format="value(parent.type)" 2>/dev/null || true)
  if [ "${PARENT_TYPE}" = "folder" ]; then
    FOLDER_ID=$(gcloud projects describe "${SSM_PROJECT}" --format="value(parent.id)" 2>/dev/null || true)
    echo "✔ Auto-detected parent Folder ID: ${FOLDER_ID}"
  else
    FOLDER_ID=""
  fi
fi

# Function to provision or validate a project with dynamic ID generation
provision_project() {
  local id_var="$1"          # e.g. DEV_PROJECT
  local name_var="$2"        # e.g. DEV_PROJECT_NAME
  local prefix_var="$3"      # e.g. DEV_PROJECT_PREFIX
  
  local current_id="${!id_var:-}"
  local name="${!name_var:-${current_id}}"
  local prefix="${!prefix_var:-df-demo}"
  
  local is_active="false"
  if [ -n "${current_id}" ]; then
    local state
    state=$(gcloud projects describe "${current_id}" --format="value(lifecycleState)" 2>/dev/null || echo "NOT_FOUND")
    if [ "${state}" = "ACTIVE" ]; then
      is_active="true"
    fi
  fi

  local target_id="${current_id}"
  if [ "${is_active}" = "true" ]; then
    echo "✔ Project ${target_id} ('${name}') already exists and is ACTIVE."
  else
    # Generate unique, compliant project ID (prefix + 4 random hex chars, length <= 30)
    local rand_suffix
    rand_suffix=$(head -c 16 /dev/urandom | shasum | head -c 4)
    target_id="${prefix}-${rand_suffix}"
    
    echo "Creating project ${target_id} with display name '${name}'..."
    if [ -n "${FOLDER_ID:-}" ]; then
      gcloud projects create "${target_id}" --name="${name}" --folder="${FOLDER_ID}" || \
      gcloud projects create "${target_id}" --name="${name}"
    else
      gcloud projects create "${target_id}" --name="${name}"
    fi
    echo "✔ Project ${target_id} created successfully."
    
    # Update config.env dynamically with new Project ID
    python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()
content = re.sub(r'^export ${id_var}=.*', 'export ${id_var}=\"${target_id}\"', content, flags=re.MULTILINE)
with open(f, 'w') as fp:
    fp.write(content)
"
  fi

  if [ -n "${BILLING_ID:-}" ]; then
    echo "Linking billing account ${BILLING_ID} to ${target_id}..."
    gcloud billing projects link "${target_id}" --billing-account="${BILLING_ID}" 2>/dev/null || \
    gcloud billing projects link "${target_id}" --billing-account="${BILLING_ID}" --billing-project="${target_id}" 2>/dev/null || true
  fi
  
  eval "${id_var}=\"${target_id}\""
}

echo "==================================================================="
echo "=== Step 1: Provisioning Projects & Enabling APIs               ==="
echo "==================================================================="

# 1. Provision all 3 projects
provision_project "DEV_PROJECT" "DEV_PROJECT_NAME" "DEV_PROJECT_PREFIX"
provision_project "PROD_PROJECT" "PROD_PROJECT_NAME" "PROD_PROJECT_PREFIX"
provision_project "SSM_PROJECT" "SSM_PROJECT_NAME" "SSM_PROJECT_PREFIX"

# Reload config.env to ensure resolved project IDs are active in current subshell
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Update workflow_settings.yaml with resolved project IDs
WORKFLOW_SETTINGS="${SCRIPT_DIR}/../workflow_settings.yaml"
if [ -f "${WORKFLOW_SETTINGS}" ]; then
  python3 -c "
import re
f = '${WORKFLOW_SETTINGS}'
with open(f, 'r') as fp:
    content = fp.read()
content = re.sub(r'defaultProject:\s*.*', 'defaultProject: ${DEV_PROJECT}', content)
content = re.sub(r'source_project:\s*.*', 'source_project: ${PROD_PROJECT}', content)
with open(f, 'w') as fp:
    fp.write(content)
"
fi

echo ""
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT} (${DEV_PROJECT_NAME})"
echo "PROD Project: ${PROD_PROJECT} (${PROD_PROJECT_NAME})"
echo "SSM Project : ${SSM_PROJECT} (${SSM_PROJECT_NAME})"
echo "Billing ID  : ${BILLING_ID:-<Auto/Unset>}"
echo "Folder ID   : ${FOLDER_ID:-<Root/Unset>}"
echo "==================================================================="

# 2. Enable Required APIs
echo ""
echo "=== Enabling Required Google Cloud APIs ==="
DATA_APIS=(
  "bigquery.googleapis.com"
  "dataform.googleapis.com"
  "developerconnect.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
  "cloudbilling.googleapis.com"
)

SSM_APIS=(
  "securesourcemanager.googleapis.com"
  "developerconnect.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
)

echo "Enabling APIs in DEV (${DEV_PROJECT})..."
gcloud services enable "${DATA_APIS[@]}" --project="${DEV_PROJECT}"

echo "Enabling APIs in PROD (${PROD_PROJECT})..."
gcloud services enable "${DATA_APIS[@]}" --project="${PROD_PROJECT}"

echo "Enabling APIs in SSM Host (${SSM_PROJECT})..."
gcloud services enable "${SSM_APIS[@]}" --project="${SSM_PROJECT}"

echo ""
echo "=== Projects & APIs Provisioned Successfully ==="
