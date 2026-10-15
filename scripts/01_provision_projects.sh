#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 1: Provisioning 3 Projects (DEV, PROD, SSM) & Enabling GCP APIs
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

echo "==================================================================="
echo "=== Step 1: Provisioning Projects & Enabling APIs               ==="
echo "==================================================================="

# -----------------------------------------------------------------------------
# 1. Billing Account Discovery & Interactive Selection
# -----------------------------------------------------------------------------
if [ -z "${BILLING_ID:-}" ]; then
  echo ">>> Discovering active Google Cloud Billing Accounts..."
  
  # Fetch all open billing accounts as lines of: ID,NAME
  ACCOUNTS_RAW=()
  while IFS= read -r line; do
    [ -n "${line}" ] && ACCOUNTS_RAW+=("${line}")
  done < <(gcloud billing accounts list --filter="open=true" --format="csv[no-heading](ACCOUNT_ID,NAME)" 2>/dev/null || true)

  NUM_ACCOUNTS=${#ACCOUNTS_RAW[@]}

  if [ "${NUM_ACCOUNTS}" -eq 0 ]; then
    echo "❌ No open billing accounts found for the current gcloud user."
    echo "Please ensure you have Billing Account Administrator / User permissions, or enter a Billing Account ID manually."
    read -r -p "Enter Billing Account ID (or press Enter to abort): " MANUAL_BILLING_ID
    if [ -z "${MANUAL_BILLING_ID}" ]; then
      echo "Aborting deployment: Billing Account is required for BigQuery and resource provisioning."
      exit 1
    fi
    BILLING_ID="${MANUAL_BILLING_ID}"
  elif [ "${NUM_ACCOUNTS}" -eq 1 ]; then
    IFS=',' read -r b_id b_name <<< "${ACCOUNTS_RAW[0]}"
    BILLING_ID="${b_id}"
    echo "✔ Auto-detected single active Billing Account: ${b_name} (${BILLING_ID})"
  else
    echo "Multiple active Billing Accounts detected:"
    for i in "${!ACCOUNTS_RAW[@]}"; do
      IFS=',' read -r b_id b_name <<< "${ACCOUNTS_RAW[$i]}"
      echo "  $((i+1))) ${b_name} (${b_id})"
    done
    
    CHOICE=0
    while [[ "${CHOICE}" -lt 1 || "${CHOICE}" -gt "${NUM_ACCOUNTS}" ]]; do
      read -r -p "Select Billing Account to link [1-${NUM_ACCOUNTS}]: " CHOICE
    done
    
    SELECTED_INDEX=$((CHOICE-1))
    IFS=',' read -r b_id b_name <<< "${ACCOUNTS_RAW[${SELECTED_INDEX}]}"
    BILLING_ID="${b_id}"
    echo "✔ Selected Billing Account: ${b_name} (${BILLING_ID})"
  fi

  # Persist BILLING_ID to config.env
  python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()
pattern = r'^export BILLING_ID=.*'
if re.search(pattern, content, flags=re.MULTILINE):
    content = re.sub(pattern, 'export BILLING_ID=\"${BILLING_ID}\"', content, flags=re.MULTILINE)
else:
    content += '\nexport BILLING_ID=\"${BILLING_ID}\"\n'
with open(f, 'w') as fp:
    fp.write(content)
"
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

# -----------------------------------------------------------------------------
# 2. Function to provision project and ensure billing is active
# -----------------------------------------------------------------------------
provision_project() {
  local id_var="$1"          # e.g. DEV_PROJECT
  local name_var="$2"        # e.g. DEV_PROJECT_NAME
  
  local current_id="${!id_var:-}"
  local name="${!name_var:-df-demo}"
  
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
    # Derive unique project ID (max 30 chars, lowercase, digits, hyphens)
    local base_slug
    base_slug=$(echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c 1-22)
    local rand_suffix
    rand_suffix=$(head -c 16 /dev/urandom | shasum | head -c 5)
    target_id="${base_slug}-${rand_suffix}"
    
    echo "Creating project ${target_id} with name '${name}'..."
    if [ -n "${FOLDER_ID:-}" ]; then
      gcloud projects create "${target_id}" --name="${name}" --folder="${FOLDER_ID}" || \
      gcloud projects create "${target_id}" --name="${name}"
    else
      gcloud projects create "${target_id}" --name="${name}"
    fi

    # Wait and verify project is ACTIVE in GCP
    local verified="false"
    for _ in {1..30}; do
      local state
      state=$(gcloud projects describe "${target_id}" --format="value(lifecycleState)" 2>/dev/null || echo "NOT_FOUND")
      if [ "${state}" = "ACTIVE" ]; then
        verified="true"
        break
      fi
      sleep 2
    done

    if [ "${verified}" != "true" ]; then
      echo "❌ Failed to create or reach project ${target_id}"
      exit 1
    fi
    echo "✔ Project ${target_id} created and is ACTIVE."
    
    # Update project ID dynamically to config.env
    python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()
pattern = r'^export ${id_var}=.*'
if re.search(pattern, content, flags=re.MULTILINE):
    content = re.sub(pattern, 'export ${id_var}=\"${target_id}\"', content, flags=re.MULTILINE)
else:
    if '# Auto-resolved Runtime Configuration' not in content:
        content += '\n# Auto-resolved Runtime Configuration (Generated at runtime)\n'
    content += 'export ${id_var}=\"${target_id}\"\n'
with open(f, 'w') as fp:
    fp.write(content)
"
  fi

  # Explicitly link billing account and wait for verification
  if [ -n "${BILLING_ID:-}" ]; then
    echo "Linking billing account ${BILLING_ID} to ${target_id}..."
    local billing_ok="false"
    for attempt in {1..20}; do
      gcloud billing projects link "${target_id}" --billing-account="${BILLING_ID}" --quiet >/dev/null 2>&1 || true
      local is_enabled
      is_enabled=$(gcloud billing projects describe "${target_id}" --format="value(billingEnabled)" 2>/dev/null || echo "False")
      if [ "${is_enabled}" = "True" ] || [ "${is_enabled}" = "true" ]; then
        billing_ok="true"
        echo "✔ Verified: Billing is ENABLED on ${target_id}."
        break
      fi
      echo "  Waiting for billing replication on ${target_id} (attempt ${attempt}/20)..."
      sleep 3
    done

    if [ "${billing_ok}" != "true" ]; then
      echo "❌ Error: Could not link billing account ${BILLING_ID} to ${target_id} after multiple attempts."
      exit 1
    fi
  else
    echo "⚠️ Warning: No BILLING_ID set. BigQuery and services may fail."
  fi
  
  eval "${id_var}=\"${target_id}\""
}

# -----------------------------------------------------------------------------
# 3. Provision all 3 projects
# -----------------------------------------------------------------------------
provision_project "DEV_PROJECT" "DEV_PROJECT_NAME"
provision_project "PROD_PROJECT" "PROD_PROJECT_NAME"
provision_project "SSM_PROJECT" "SSM_PROJECT_NAME"

# Synchronize derived runtime variables to config.env
python3 -c "
import re
f = '${CONFIG_FILE}'
with open(f, 'r') as fp:
    content = fp.read()

runtime_vars = [
    ('DEV_PROJECT', '${DEV_PROJECT}'),
    ('PROD_PROJECT', '${PROD_PROJECT}'),
    ('SSM_PROJECT', '${SSM_PROJECT}'),
    ('EXECUTOR_SA', 'dataform-executor@${DEV_PROJECT}.iam.gserviceaccount.com'),
    ('SOURCE_PROJECT', '${PROD_PROJECT}'),
    ('TARGET_PROJECT', '${DEV_PROJECT}')
]

for var_name, var_val in runtime_vars:
    pattern = r'^export ' + var_name + r'=.*'
    if re.search(pattern, content, flags=re.MULTILINE):
        content = re.sub(pattern, f'export {var_name}=\"{var_val}\"', content, flags=re.MULTILINE)
    else:
        if '# Auto-resolved Runtime Configuration' not in content:
            content += '\n# Auto-resolved Runtime Configuration (Generated at runtime)\n'
        content += f'export {var_name}=\"{var_val}\"\n'

with open(f, 'w') as fp:
    fp.write(content)
"

# Reload config.env
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
echo "DEV Project : ${DEV_PROJECT} (Name: ${DEV_PROJECT_NAME})"
echo "PROD Project: ${PROD_PROJECT} (Name: ${PROD_PROJECT_NAME})"
echo "SSM Project : ${SSM_PROJECT} (Name: ${SSM_PROJECT_NAME})"
echo "Billing ID  : ${BILLING_ID:-<Auto/Unset>}"
echo "Folder ID   : ${FOLDER_ID:-<Root/Unset>}"
echo "==================================================================="

# -----------------------------------------------------------------------------
# 4. Enable Required APIs and Wait for Completion
# -----------------------------------------------------------------------------
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
