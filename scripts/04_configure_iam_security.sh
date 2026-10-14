#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 4: Configuring Service Accounts, Least-Privilege IAM & Dataset Security
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Auto-resolve placeholder developer identity to active gcloud account
if [[ "${DEVELOPER:-}" == *"@mydomain.com"* ]] || [ -z "${DEVELOPER:-}" ]; then
  DEVELOPER=$(gcloud config get-value account 2>/dev/null || echo "${DEVELOPER}")
fi

echo "==================================================================="
echo "=== Step 4: Configuring Service Accounts & IAM Security         ==="
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "Developer   : ${DEVELOPER}"
echo "==================================================================="

# Step 1: Create Pipeline Execution Service Account
echo ""
echo "--- Step 1: Creating Pipeline Execution Service Account (${EXECUTOR_SA}) ---"
if ! gcloud iam service-accounts describe "${EXECUTOR_SA}" --project="${DEV_PROJECT}" >/dev/null 2>&1; then
  echo "Creating dataform-executor service account in ${DEV_PROJECT}..."
  gcloud iam service-accounts create dataform-executor \
    --display-name="Dataform Pipeline Executor" \
    --project="${DEV_PROJECT}"
else
  echo "✔ dataform-executor service account already exists in ${DEV_PROJECT}."
fi

echo "Executor Service Account: ${EXECUTOR_SA}"

# Step 2: Initialize / Obtain Dataform & Developer Connect Service Agents
echo ""
echo "--- Step 2: Initializing Service Agents ---"
gcloud beta services identity create --service=dataform.googleapis.com --project="${DEV_PROJECT}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=dataform.googleapis.com --project="${PROD_PROJECT}" >/dev/null 2>&1 || true

DEV_PROJECT_NUM=$(gcloud projects describe "${DEV_PROJECT}" --format="value(projectNumber)")
PROD_PROJECT_NUM=$(gcloud projects describe "${PROD_PROJECT}" --format="value(projectNumber)")

DEV_DATAFORM_SA="service-${DEV_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"
PROD_DATAFORM_SA="service-${PROD_PROJECT_NUM}@gcp-sa-dataform.iam.gserviceaccount.com"

echo "DEV Dataform SA : ${DEV_DATAFORM_SA}"
echo "PROD Dataform SA: ${PROD_DATAFORM_SA}"

# Step 3: Grant Project-Level BigQuery & Dataform Roles
echo ""
echo "--- Step 3: Granting Project-Level Roles ---"

# Developer Permissions
echo "Granting roles/viewer, roles/dataform.editor & bigquery.jobUser to Developer (${DEVELOPER}) in DEV..."
gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/viewer" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/dataform.editor" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/bigquery.jobUser" \
  --condition=None >/dev/null 2>&1 || true

echo "Granting roles/viewer to Developer (${DEVELOPER}) in PROD (${PROD_PROJECT})..."
gcloud projects add-iam-policy-binding "${PROD_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/viewer" \
  --condition=None >/dev/null 2>&1 || true

echo "Granting roles/viewer & securesourcemanager.instanceAccessor to Developer (${DEVELOPER}) in SSM (${SSM_PROJECT})..."
gcloud projects add-iam-policy-binding "${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/viewer" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${SSM_PROJECT}" \
  --member="user:${DEVELOPER}" \
  --role="roles/securesourcemanager.instanceAccessor" \
  --condition=None >/dev/null 2>&1 || true

# Dataform Service Agents Permissions
echo "Granting bigquery.jobUser to Dataform Service Agents..."
gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${PROD_PROJECT}" \
  --member="serviceAccount:${PROD_DATAFORM_SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None >/dev/null 2>&1 || true

# Pipeline Executor SA Permissions
echo "Granting bigquery.jobUser to Pipeline Executor SA (${EXECUTOR_SA})..."
gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${EXECUTOR_SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${PROD_PROJECT}" \
  --member="serviceAccount:${EXECUTOR_SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None >/dev/null 2>&1 || true

# Grant Dataform SA permission to impersonate Executor SA
echo "Granting roles/iam.serviceAccountTokenCreator on Executor SA to Dataform SA..."
gcloud iam service-accounts add-iam-policy-binding "${EXECUTOR_SA}" \
  --project="${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --condition=None >/dev/null 2>&1 || true

# Grant project-level BigQuery Data Editor to Dataform SA in DEV (enables automatic sandbox dataset creation)
echo "Granting roles/bigquery.dataEditor to Dataform SA in DEV (${DEV_PROJECT})..."
gcloud projects add-iam-policy-binding "${DEV_PROJECT}" \
  --member="serviceAccount:${DEV_DATAFORM_SA}" \
  --role="roles/bigquery.dataEditor" \
  --condition=None >/dev/null 2>&1 || true

# Step 4: Grant Granular Dataset-Level Roles
echo ""
echo "--- Step 4: Granting Granular Dataset-Level Roles ---"

python3 - <<EOF
import subprocess
import json
import tempfile
import sys

def grant_dataset_role(project, dataset, member, role):
    target = f"{project}:{dataset}"
    try:
        res = subprocess.run(
            ["bq", "show", "--format=prettyjson", target],
            capture_output=True,
            text=True,
            check=True
        )
        ds_data = json.loads(res.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error fetching metadata for {target}: {e.stderr}", file=sys.stderr)
        return

    access = ds_data.get("access", [])
    
    # Check if entry already exists
    for entry in access:
        if entry.get("role") == role:
            if (entry.get("userByEmail") == member or 
                entry.get("iamMember") == member or 
                entry.get("iamMember") == f"user:{member}" or 
                entry.get("iamMember") == f"serviceAccount:{member}"):
                print(f"[EXISTS] {target} already has {role} for {member}")
                return

    # Add access entry
    if "@" in member and not member.endswith(".iam.gserviceaccount.com") and not member.startswith("service-"):
        new_entry = {"role": role, "userByEmail": member}
    else:
        new_entry = {"role": role, "iamMember": f"serviceAccount:{member}" if not member.startswith("serviceAccount:") else member}
    access.append(new_entry)
    
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
        json.dump({"access": access}, tf)
        tmp_file = tf.name

    try:
        subprocess.run(
            ["bq", "update", f"--source={tmp_file}", target],
            capture_output=True,
            text=True,
            check=True
        )
        print(f"[GRANTED] {target} -> {role} to {member}")
    except subprocess.CalledProcessError as e:
        print(f"Error updating {target}: {e.stderr}", file=sys.stderr)

dev_proj = "${DEV_PROJECT}"
prod_proj = "${PROD_PROJECT}"
developer = "${DEVELOPER}"
dev_sa = "${DEV_DATAFORM_SA}"
prod_sa = "${PROD_DATAFORM_SA}"
executor_sa = "${EXECUTOR_SA}"

# 1. DEV Dataset Permissions
grant_dataset_role(dev_proj, "analytics_curated", developer, "roles/bigquery.dataViewer")
grant_dataset_role(dev_proj, "dataform_assertions", developer, "roles/bigquery.dataViewer")
grant_dataset_role(dev_proj, "analytics_curated", dev_sa, "roles/bigquery.dataEditor")
grant_dataset_role(dev_proj, "dataform_assertions", dev_sa, "roles/bigquery.dataEditor")
grant_dataset_role(dev_proj, "analytics_curated", executor_sa, "roles/bigquery.dataEditor")
grant_dataset_role(dev_proj, "dataform_assertions", executor_sa, "roles/bigquery.dataEditor")

# 2. PROD Dataset Permissions (Locked Vault + Curated Outputs)
grant_dataset_role(prod_proj, "raw_vault", developer, "roles/bigquery.dataViewer")
grant_dataset_role(prod_proj, "raw_vault", dev_sa, "roles/bigquery.dataViewer")
grant_dataset_role(prod_proj, "raw_vault", prod_sa, "roles/bigquery.dataViewer")
grant_dataset_role(prod_proj, "raw_vault", executor_sa, "roles/bigquery.dataViewer")

grant_dataset_role(prod_proj, "analytics_curated", prod_sa, "roles/bigquery.dataEditor")
grant_dataset_role(prod_proj, "dataform_assertions", prod_sa, "roles/bigquery.dataEditor")
grant_dataset_role(prod_proj, "analytics_curated", executor_sa, "roles/bigquery.dataEditor")
grant_dataset_role(prod_proj, "dataform_assertions", executor_sa, "roles/bigquery.dataEditor")

EOF

echo ""
echo "=== Step 4 IAM Security Configuration Completed Successfully ==="
