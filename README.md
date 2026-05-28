# cloudrun-cloudsql-to-bq-daily-job

Cloud Run Job that copies rows from a CloudSQL (MySQL) table into a
date-partitioned BigQuery table.

## How it works

- Connects to CloudSQL via the Cloud SQL Python Connector (no proxy sidecar).
- Reads the DB password from Secret Manager.
- Runs ``SELECT * FROM <source_table> WHERE DATE(<date_column>) BETWEEN :start AND :end``.
- Loads NDJSON into BigQuery:
  - **Single day** (default, or via `LOAD_DATE`): `WRITE_TRUNCATE` on the
    `$YYYYMMDD` partition — idempotent for daily reruns.
  - **Range** (`START_DATE` + `END_DATE`, different days): `WRITE_APPEND`
    to the base table — *not* idempotent; reruns duplicate rows.

## Project layout

```
orders_cstobq_etl/
├── main.py             # Entry point
├── cloudsql_connect.py # CloudSQL engine (context-managed)
├── orders_etl.py       # extract_rows + load_rows
└── gcp_secrets.py      # Secret Manager access
Dockerfile
cloudbuild_job.yaml     # Build + push + deploy pipeline
requirements.txt
```

## Environment variables

| Var | Required | Default |
|---|---|---|
| `GCP_PROJECT` | yes | — |
| `INSTANCE_CONNECTION_NAME` | yes | — |
| `DB_NAME` | yes | — |
| `DB_USER` | yes | — |
| `DB_PASSWORD_SECRET` | yes | — (bare name, secret path, or full version path) |
| `BQ_DATASET` | yes | — |
| `BQ_TABLE` | yes | — |
| `SOURCE_TABLE` | no | `orders` |
| `ORDER_DATE_COLUMN` | no | `order_date` |
| `LOAD_DATE` | no | yesterday UTC |
| `START_DATE` + `END_DATE` | no | — (must be set together) |

Date-selection priority: `START_DATE`+`END_DATE` → `LOAD_DATE` → yesterday UTC.

## Required setup

### 1. Destination BigQuery table

Must already exist, partitioned on the date column. Example:

```sql
CREATE TABLE `cloud-gcpt-0526.shopeasy_retail_analytics.orders`(
  order_id            INT64,
  customer_email      STRING,
  customer_mobile     STRING,
  order_date          DATE,
  product             STRING,
  quantity            INT64,
  total_amount        NUMERIC,
  order_status        STRING,
  shipping_address_id INT64,
  created_at          TIMESTAMP,
  updated_at          TIMESTAMP,
  bq_create_ts        TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
PARTITION BY order_date;
```

The job uses `SELECT *` from MySQL; column names must match the BQ table
(BQ load is case-sensitive). `bq_create_ts` is filled by BQ's `DEFAULT`.

### 2. Service accounts

| SA | Purpose |
|---|---|
| `cloud-build-deploy-bot@PROJECT.iam.gserviceaccount.com` | Attached to Cloud Build for image push + Cloud Run deploy |
| `cloudrun-workloads-bot@PROJECT.iam.gserviceaccount.com` | Identity of the Cloud Run Job at runtime |
| `scheduled-jobs-trigger-bot@PROJECT.iam.gserviceaccount.com` | Identity used by Cloud Scheduler to trigger the job |

### 3. IAM bindings (per SA)

**Build/deploy SA** — `cloud-build-deploy-bot`

- `roles/artifactregistry.writer` (Artifact Registry Writer)
- `roles/run.admin` (Cloud Run Admin)
- `roles/logging.logWriter` (Logs Writer)
- `roles/iam.serviceAccountUser` (Service Account User) — on the runtime SA
- `roles/storage.objectViewer` (Storage Object Viewer)

**Runtime SA** — `cloudrun-workloads-bot`

- `roles/bigquery.dataEditor` (BigQuery Data Editor)
- `roles/bigquery.jobUser` (BigQuery Job User)
- `roles/cloudsql.client` (Cloud SQL Client)
- `roles/cloudsql.instanceUser` (Cloud SQL Instance User)
- `roles/secretmanager.secretAccessor` (Secret Manager Secret Accessor)

**Scheduler trigger SA** — `scheduled-jobs-trigger-bot`

- `roles/run.developer` (Cloud Run Developer) — on the Cloud Run Job (or project)
- `roles/run.invoker` (Cloud Run Invoker)
- `roles/iam.serviceAccountTokenCreator` (Service Account Token Creator) — granted
  **to the Cloud Scheduler service agent**
  (`service-<PROJECT_NUMBER>@gcp-sa-cloudscheduler.iam.gserviceaccount.com`)
  on this trigger SA, so Scheduler can mint OAuth tokens for it.
- `iamcredentials.googleapis.com` must be enabled in the project.

> **Why `run.developer`, not `run.invoker`?** When the Scheduler body contains
> `containerOverrides`, Cloud Run requires the additional permission
> `run.jobs.runWithOverrides`, which `roles/run.invoker` does *not* include.
> Symptom of missing it: empty body triggers fine; body with overrides
> returns HTTP 403 / Scheduler `status.code: 7`.

### 4. Secret

```bash
printf '%s' "$DB_PASSWORD" \
  | gcloud secrets create CLOUDSQL-RETAIL-DB-PASS --data-file=-
```

## Build & deploy

```bash
gcloud builds submit --config=cloudbuild_job.yaml
```

`cloudbuild_job.yaml` does three things: builds the Docker image, pushes
two tags (`:${SHORT_SHA}` and `:latest`) to Artifact Registry, then creates
or updates the Cloud Run Job with all env vars wired from substitutions.

## Trigger from Cloud Scheduler

The Cloud Run Jobs v2 API endpoint:

```
POST https://<REGION>-run.googleapis.com/v2/projects/<PROJECT>/locations/<REGION>/jobs/<JOB>:run
```

Authenticate via OAuth using the scheduler invoker SA.

### Per-execution overrides

Env vars passed in the request body apply **only to that execution** — the
deployed job's vars stay unchanged. Anything you don't override falls back
to the deploy-time value. Only these vars are meant to be overridden:

- `BQ_DATASET`, `BQ_TABLE`
- `SOURCE_TABLE`, `ORDER_DATE_COLUMN`
- `LOAD_DATE` / `START_DATE` / `END_DATE`

**Daily run (yesterday UTC)**

```json
{
  "overrides": {
    "containerOverrides": [{
      "env": [
        { "name": "BQ_DATASET",        "value": "shopeasy_retail_analytics" },
        { "name": "BQ_TABLE",          "value": "orders" },
        { "name": "SOURCE_TABLE",      "value": "orders" },
        { "name": "ORDER_DATE_COLUMN", "value": "order_date" }
      ]
    }]
  }
}
```

**Single-day load**

```json
{
  "overrides": {
    "containerOverrides": [{
      "env": [
        { "name": "BQ_DATASET",        "value": "shopeasy_retail_analytics" },
        { "name": "BQ_TABLE",          "value": "orders" },
        { "name": "SOURCE_TABLE",      "value": "orders" },
        { "name": "ORDER_DATE_COLUMN", "value": "order_date" },
        { "name": "LOAD_DATE",         "value": "2026-05-22" }
      ]
    }]
  }
}
```

**Range backfill**

```json
{
  "overrides": {
    "containerOverrides": [{
      "env": [
        { "name": "BQ_DATASET",        "value": "shopeasy_retail_analytics" },
        { "name": "BQ_TABLE",          "value": "orders" },
        { "name": "SOURCE_TABLE",      "value": "orders" },
        { "name": "ORDER_DATE_COLUMN", "value": "order_date" },
        { "name": "START_DATE",        "value": "2026-04-01" },
        { "name": "END_DATE",          "value": "2026-04-30" }
      ]
    }]
  }
}
```

### Create the Scheduler job

```bash
gcloud scheduler jobs create http cloudsql-to-bq-daily \
  --location=asia-south1 \
  --schedule="30 1 * * *" --time-zone=UTC \
  --uri="https://asia-south1-run.googleapis.com/v2/projects/cloud-gcpt-0526/locations/asia-south1/jobs/cloudsql-to-bq-daily-batch-job:run" \
  --http-method=POST \
  --headers="Content-Type=application/json" \
  --message-body='{"overrides":{"containerOverrides":[{"env":[{"name":"BQ_DATASET","value":"shopeasy_retail_analytics"},{"name":"BQ_TABLE","value":"orders"},{"name":"SOURCE_TABLE","value":"orders"},{"name":"ORDER_DATE_COLUMN","value":"order_date"}]}]}}' \
  --oauth-service-account-email=scheduled-jobs-trigger-bot@cloud-gcpt-0526.iam.gserviceaccount.com
```

### Fire on demand (test the schedule entry without waiting)

```bash
gcloud scheduler jobs run cloudsql-to-bq-daily --location=asia-south1
```

### Manual ad-hoc trigger (no scheduler)

```bash
gcloud run jobs execute cloudsql-to-bq-daily-batch-job --region=asia-south1
```

Note: `gcloud run jobs execute --update-env-vars=...` **persists** the change
on the job. Prefer the Scheduler override path for per-execution values.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `status.code: 7` / HTTP 403, empty body works, body with overrides fails | Trigger SA only has `run.invoker`; missing `run.jobs.runWithOverrides` | Grant `roles/run.developer` (or a custom role with `run.jobs.run` + `run.jobs.runWithOverrides`) |
| `status.code: 7` even with empty body | Cloud Scheduler service agent missing `iam.serviceAccountTokenCreator` on the trigger SA | `gcloud iam service-accounts add-iam-policy-binding <trigger-sa> --member="serviceAccount:service-<PROJECT_NUMBER>@gcp-sa-cloudscheduler.iam.gserviceaccount.com" --role=roles/iam.serviceAccountTokenCreator` |
| Scheduler never attempts (no `lastAttemptTime`) | `iamcredentials.googleapis.com` not enabled | `gcloud services enable iamcredentials.googleapis.com` |
| Scheduler URI returns 404 | Missing regional prefix in URI | Use `https://<REGION>-run.googleapis.com/v2/...`, not bare `run.googleapis.com` |
| Body gets mangled on `gcloud scheduler jobs update http` | Wrong flag — `--headers` is `create`-only | Use `--update-headers` on `update http` |

To diagnose 403s authoritatively:

```bash
gcloud policy-troubleshoot iam //run.googleapis.com/projects/<PROJECT>/locations/<REGION>/jobs/<JOB> \
  --permission=run.jobs.run \
  --principal-email=<trigger-sa-email>
```

`access: GRANTED` confirms the IAM allow path; if you still get 403 with overrides, it's the runWithOverrides permission gap above.

## Local test

```bash
pip install -r requirements.txt
gcloud auth application-default login

export GCP_PROJECT=cloud-gcpt-0526
export INSTANCE_CONNECTION_NAME=cloud-gcpt-0526:asia-south1:shopeasy
export DB_NAME=retail_db
export DB_USER=retail-rw-user
export DB_PASSWORD_SECRET=CLOUDSQL-RETAIL-DB-PASS
export BQ_DATASET=shopeasy_retail_analytics
export BQ_TABLE=orders

python orders_cstobq_etl/main.py
```
