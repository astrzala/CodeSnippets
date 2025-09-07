# 🔄 Microsoft Fabric Capacity Auto-Pause Runbook

This runbook automatically **pauses your Microsoft Fabric capacity** when there has been no activity for a configurable window (default: 90 minutes).  
It uses **Azure Automation (PowerShell 7)** + **Managed Identity** + the official **Fabric Capacity Metrics App** semantic model.

---

## 🔑 Key Features
- ⏱️ **Auto-pause** Fabric capacities with no detected activity.
- 📊 **Activity detection** via DirectQuery tables in the *Capacity Metrics* semantic model.
- 🧩 **Granular insights**: summary of recent operations by type (Interactive/Background) and operation name.
- 🛡️ **Safe defaults**: requires continuous inactivity before pausing; conservatively skips pausing on errors.
- 🌐 **Runs serverless** inside Azure Automation with a Managed Identity (no secrets).

---

## ⚙️ How It Works
1. Runbook queries the **ARM API** to check Fabric capacity state.
2. Uses the **Power BI ExecuteQueries REST API** against the *Capacity Metrics* dataset:
   - `TimePointInteractiveDetail` → user/interactive operations (queries, adhoc analysis).
   - `TimePointBackgroundDetail` → background jobs (refreshes, pipelines, notebooks, warehouses).
3. If no rows exist within the **QuietMinutes** window (default: 90), the capacity is **suspended** using the ARM `suspend` endpoint.
4. Logs a **summary of activity kinds** and **Top-10 most recent operations** for observability.

---

## ✅ Prerequisites
- **Microsoft Fabric capacity** (F-SKU) deployed in your subscription.
- **Azure Automation Account** with:
  - PowerShell 7 runtime
  - System-Assigned or User-Assigned Managed Identity
- Managed Identity must have:
  - `Contributor` role on the Fabric capacity resource
  - `Viewer` (and `Build`) permissions in the *Microsoft Fabric Capacity Metrics* workspace + dataset
- **Tenant settings** enabled in Power BI Admin Portal:
  - ✅ *Service principals can use Power BI APIs*
  - ✅ *Allow service principals to use ExecuteQueries API*

---

## 🚀 Setup and Usage
1. **Deploy script** as a runbook (`Check-And-Pause-Fabric.ps1`) in your Automation Account.
2. **Import parameters** (SubscriptionId, ResourceGroup, CapacityName, MetricsGroupId, MetricsDatasetId).
3. **Schedule** the runbook every 15 minutes.
4. (Optional) Create a companion `Resume-Fabric.ps1` runbook + webhook for on-demand wake-up.
5. Monitor runbook logs for activity summaries and pause events.

---

## 🎛️ Parameters
| Name              | Type   | Required | Default | Description |
|-------------------|--------|----------|---------|-------------|
| `SubscriptionId`  | string | ✅       | –       | Azure subscription hosting the capacity |
| `ResourceGroup`   | string | ✅       | –       | Resource Group of the capacity |
| `CapacityName`    | string | ✅       | –       | Azure Resource Name of the Fabric capacity (e.g. `fabricdev01`) |
| `MetricsGroupId`  | string | ✅       | –       | Workspace ID of the *Capacity Metrics* app |
| `MetricsDatasetId`| string | ✅       | –       | Dataset ID of the *Capacity Metrics* semantic model |
| `QuietMinutes`    | int    | ❌       | `90`    | Window of inactivity before suspension |

---

## ✔️ Valid Operations
Activity is counted if any of the following occur within the window:
- **Interactive operations** (from `TimePointInteractiveDetail`):
  - DAX/SQL queries
  - Live report interactions
  - Ad-hoc analysis
- **Background operations** (from `TimePointBackgroundDetail`):
  - Dataset refresh
  - Dataflow Gen2 refresh
  - Pipelines execution
  - Notebook / Spark job
  - Warehouse / Lakehouse loads

Runbook logs show:
- 📊 **Summary**: `Type | Operation → Count`
- 📄 **Top 10 details**: `Type | Operation | Status | User | Timestamp`

---

## ⚠️ Error Handling
- If the ARM call fails → runbook throws with full diagnostic output.
- If ExecuteQueries returns **400 (Bad Request)** → error body is logged, runbook assumes **no activity** (so capacity may suspend).
- If ExecuteQueries fails for other reasons → warning logged, runbook assumes **no activity**.
- Conservative defaults:
  - Use **QuietMinutes ≥ 90** and **schedule every 15 min** to avoid false pauses.
  - Logs clearly indicate *why* suspension was skipped or executed.

---

## 📌 Example Log Output

