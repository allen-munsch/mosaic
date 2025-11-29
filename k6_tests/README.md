# k6 Load Testing for MosaicDB

This directory contains the `k6` load testing setup for MosaicDB, including a sample dataset, data ingestion script, and the load testing script itself.

## 1. Prerequisites

Before running the tests, ensure you have:
*   Docker and Docker Compose installed.
*   The `mosaic` project cloned.

## 2. Setup the Environment

1.  **Build and Start MosaicDB with k6:**
    The `docker-compose.yml` has been updated to include the `mosaic` application and `k6` service.
    ```bash
    docker-compose up -d --build
    ```
    This will start:
    *   `mosaic`: Your Elixir application.
    *   `k6`: The load testing tool (running `sleep infinity` initially).
    *   `redis`, `nginx`, `prometheus`, `grafana`: Supporting services.

2.  **Verify MosaicDB Health:**
    Wait for the `mosaic` service to be healthy. You can check its logs:
    ```bash
    docker-compose logs -f mosaic
    ```
    Look for messages indicating the Phoenix server is running and the `/health` endpoint is responsive.

3.  **Seed Initial Data (Functional & Load Test Preparation):**
    The `k6` `setup()` function includes a basic health check. For the load test to have data to query, you need to ingest the sample dataset.

    Run the ingestion script in the `mosaic` container:
    ```bash
    docker-compose exec mosaic mix run scripts/ingest_data.exs data/sample_dataset.jsonl
    ```
    Verify the data is indexed by checking `mosaic` logs or querying an API endpoint directly if you have one available to list documents.

## 3. Running the Load Test

1.  **Ensure core services are running:**
    If you haven't already, start your core services (excluding `k6` by default):
    ```bash
    docker compose up -d --build
    ```
    Wait for the `mosaic` service to be healthy. You can check its logs:
    ```bash
    docker compose logs -f mosaic
    ```
    Look for messages indicating the application has started and is responsive to health checks.

2.  **Execute the k6 test:**
    Once MosaicDB is up and healthy, execute the `k6` test script using the `load-test` profile. This command will start a temporary `k6` container, run the test, and remove the container afterward. The initial data seeding (via API) will automatically happen in `k6`'s `setup()` phase.

    ```bash
    docker compose --profile load-test run --rm --name k6_test_run k6 run k6_tests/load_test.js
    ```
    *   `--profile load-test`: Activates the services defined under the `load-test` profile (i.e., the `k6` service).
    *   `run`: Starts a one-off container for the `k6` service.
    *   `--rm`: Removes the container after it exits.
    *   `--name k6_test_run`: Assigns a temporary name to the container for this specific run.
    *   `k6 run k6_tests/load_test.js`: This is the command executed inside the `k6` container, telling `k6` to run your test script.

## 4. Test Scenarios & Metrics

The `k6_tests/load_test.js` script defines a `ramping-vus` scenario:
*   **Virtual Users (VUs):** Ramps up from 0 to 20 VUs over 30 seconds, then stays at 20 VUs for another 30 seconds.
*   **Duration:** 1 minute.
*   **Workload:** VUs are split (even/odd) to perform a mix of:
    *   **Search Operations:** Semantic search (`/api/search`) and Hybrid search (`/api/search/hybrid`). Queries are dynamically generated from the `sample_dataset.jsonl`.
    *   **Indexing Operations:** Indexing new (or re-indexing existing) documents (`/api/documents`).
    *   **Analytics Queries:** Simulating complex SQL queries (`/api/query`) and explicit DuckDB queries (`/api/analytics`).
    *   **Admin Operations:** Checking shard status (`/api/shards`), refreshing DuckDB (`/api/admin/refresh-duckdb`), and fetching metrics (`/api/metrics`).

**Key Performance Indicators (KPIs) and Thresholds:**
The `options.thresholds` in `load_test.js` define the success criteria:
*   `http_req_duration`: 95% of all HTTP requests should complete within 500ms.
*   `errors`: Overall error rate for all checks should be below 1%.
*   `search_duration`: 95% of search operations should complete within 300ms.
*   `index_duration`: 95% of indexing operations should complete within 800ms.
*   `query_duration`: 95% of analytics queries should complete within 400ms.

## 5. Interpreting Results

After the `k6 run` command finishes, it will output a summary of the test results directly to your terminal.

**Key sections to look for:**
*   **`http_req_duration`**: Average, P(90), P(95), P(99) response times for all HTTP requests.
*   **`http_reqs`**: Total number of HTTP requests made.
*   **`iterations`**: Total number of times the `default` function in `load_test.js` was executed.
*   **`checks`**: Percentage of successful `check()` assertions. This should ideally be 100%.
*   **`errors`**: The overall error rate for failed checks or HTTP requests.
*   **Custom Metrics (`search_duration`, `index_duration`, `query_duration`)**: These provide more granular response time metrics for specific operations.

If any thresholds are violated, `k6` will report a "FAIL" status.

## 6. Next Steps

*   **Expand Dataset:** Replace `sample_dataset.jsonl` with a larger, more realistic dataset for thorough testing.
*   **Refine Scenarios:** Adjust `vus`, `duration`, `stages`, and the mix of operations in `load_test.js` to simulate your specific production workload.
*   **Advanced Metrics:** Integrate `k6` with Prometheus and Grafana (already part of the `docker-compose.yml`) for rich, real-time visualization of test results. You can access Grafana at `http://localhost:3000` (admin/admin).
*   **Parameterized Tests:** Use different datasets or query parameters to test various aspects of MosaicDB.