#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Step 2: Creating Core BigQuery Datasets in DEV and PROD
# (Developer sandbox datasets are automatically created on first execution by Dataform)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==================================================================="
echo "=== Step 2: Creating Core BigQuery Datasets                     ==="
echo "==================================================================="
echo "DEV Project : ${DEV_PROJECT}"
echo "PROD Project: ${PROD_PROJECT}"
echo "Location    : ${LOCATION}"
echo "==================================================================="

echo ">>> Creating BigQuery Datasets in PROD (${PROD_PROJECT}) in ${LOCATION}..."
# 1. PROD: raw_vault (Read-Only Source)
bq --location="${LOCATION}" mk --dataset \
  --description="Production locked raw data vault for source transactions" \
  "${PROD_PROJECT}:raw_vault" 2>/dev/null || echo "raw_vault already exists in PROD"

# 2. PROD: analytics_curated
bq --location="${LOCATION}" mk --dataset \
  --description="Production curated analytics dataset" \
  "${PROD_PROJECT}:analytics_curated" 2>/dev/null || echo "analytics_curated already exists in PROD"

# 3. PROD: dataform_assertions
bq --location="${LOCATION}" mk --dataset \
  --description="Production Dataform test assertions dataset" \
  "${PROD_PROJECT}:dataform_assertions" 2>/dev/null || echo "dataform_assertions already exists in PROD"

echo ""
echo ">>> Creating BigQuery Datasets in DEV (${DEV_PROJECT}) in ${LOCATION}..."
# 4. DEV: analytics_curated (Shared Integration Dataset)
bq --location="${LOCATION}" mk --dataset \
  --description="DEV curated analytics default dataset" \
  "${DEV_PROJECT}:analytics_curated" 2>/dev/null || echo "analytics_curated already exists in DEV"

# 5. DEV: dataform_assertions
bq --location="${LOCATION}" mk --dataset \
  --description="DEV Dataform test assertions dataset" \
  "${DEV_PROJECT}:dataform_assertions" 2>/dev/null || echo "dataform_assertions already exists in DEV"

echo ""
echo "✔ Core datasets created. Note: Developer sandbox datasets (e.g., analytics_curated__alice) are dynamically created on first execution by Dataform."
