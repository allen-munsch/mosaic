// k6_tests/load_test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Trend, Rate } from 'k6/metrics';

// Custom metrics
const searchTrend = new Trend('search_duration');
const indexTrend = new Trend('index_duration');
const queryTrend = new Trend('query_duration');
const errorRate = new Rate('errors');

// Test configuration
export const options = {
    vus: 10, // Virtual users

    thresholds: {
        'http_req_duration': ['p(95)<500'], // 95% of requests should be below 500ms
        'errors': ['rate<0.01'], // Error rate should be less than 1%
        'search_duration': ['p(95)<300'],
        'index_duration': ['p(95)<800'],
        'query_duration': ['p(95)<400'],
    },
    scenarios: {
        ramping_vus_scenario: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '30s', target: 20 }, // ramp up to 20 VUs over 30 seconds
                { duration: '30s', target: 20 }, // stay at 20 VUs for 30 seconds
            ],
            gracefulRampDown: '0s',
        },
    },
};

// Load data once per test run
const docs = new SharedArray('documents', function () {
    const fileContent = open('../data/sample_dataset.jsonl');
    // Split the content by newline and filter out empty lines, then parse each line
    return fileContent.split('\n').filter(line => line.trim() !== '').map(line => JSON.parse(line));
});


export function setup() {
    console.log('k6 setup phase: Initializing data for MosaicDB...');

    // 1. Health Check
    const healthRes = http.get('http://mosaic:4040/health');
    check(healthRes, { 'MosaicDB healthcheck passed': (r) => r.status === 200 && r.body === 'ok' });

    if (healthRes.status !== 200) {
        console.error('MosaicDB healthcheck failed. Aborting setup.');
        return { abort: true };
    }

    // 2. Initial Data Seeding via API
    console.log(`Ingesting ${docs.length} documents into MosaicDB via API...`);
    docs.forEach((doc, index) => {
        const payload = JSON.stringify(doc);
        const params = {
            headers: {
                'Content-Type': 'application/json',
            },
        };
        const res = http.post('http://mosaic:4040/api/documents', payload, params);
        check(res, { [`document ${doc.id} indexed successfully (status 201)`]: (r) => r.status === 201 });
        if (res.status !== 201) {
            console.error(`Failed to ingest document ${doc.id}: ${res.status} - ${res.body}`);
            // Optionally, abort if a critical number of documents fail to ingest
        }
        sleep(0.1); // Small delay to prevent overwhelming during setup
    });

    console.log('Initial data ingestion complete. Proceeding to test execution.');
    return { data_seeded: true };
}

export default function () {
    // Each VU executes this function repeatedly

    // Simulate various user actions
    if (__VU % 2 === 0) { // Even VUs perform searches
        searchScenario();
    } else { // Odd VUs perform indexing
        indexScenario();
    }

    // Occasionally perform analytics queries or check shards
    if (__ITER % 10 === 0) { // Every 10th iteration
        queryScenario();
    }
    if (__ITER % 20 === 0) { // Every 20th iteration
        adminScenario();
    }

    sleep(1); // Simulate user think time
}

function searchScenario() {
    const params = {
        headers: {
            'Content-Type': 'application/json',
        },
    };

    // Randomly pick a query from the dataset
    const randomDoc = docs[Math.floor(Math.random() * docs.length)];
    const query = randomDoc.text.split(' ').slice(0, 5).join(' '); // Use first 5 words as query

    const payload = JSON.stringify({ query: query });
    let res;

    // Simulate semantic search
    res = http.post('http://mosaic:4040/api/search', payload, params);
    check(res, { 'semantic search status is 200': (r) => r.status === 200 });
    searchTrend.add(res.timings.duration);
    errorRate.add(res.status !== 200);

    sleep(0.5); // Think time

    // Simulate hybrid search
    const whereClause = `metadata->>'rating' >= '4'`; // Example SQL filter
    const hybridPayload = JSON.stringify({ query: query, where: whereClause });
    res = http.post('http://mosaic:4040/api/search/hybrid', hybridPayload, params);
    check(res, { 'hybrid search status is 200': (r) => r.status === 200 });
    searchTrend.add(res.timings.duration);
    errorRate.add(res.status !== 200);
}

function indexScenario() {
    const params = {
        headers: {
            'Content-Type': 'application/json',
        },
    };

    // Index a new document (or re-index an existing one with new data)
    // For a real load test, you'd generate unique IDs or use a separate stream of new documents.
    // Here, we re-index a random doc to keep the example simple.
    const randomDoc = docs[Math.floor(Math.random() * docs.length)];
    const newDocId = `new_doc_${__VU}_${__ITER}`;
    const newDoc = {
        id: newDocId,
        text: `This is a new review from VU ${__VU}, iteration ${__ITER}. ${randomDoc.text}`,
        metadata: { ...randomDoc.metadata, indexed_by_k6: true }
    };

    const payload = JSON.stringify(newDoc);
    const res = http.post('http://mosaic:4040/api/documents', payload, params);
    check(res, { 'index document status is 201': (r) => r.status === 201 });
    indexTrend.add(res.timings.duration);
    errorRate.add(res.status !== 201);
}

function queryScenario() {
    const params = {
        headers: {
            'Content-Type': 'application/json',
        },
    };

    // Simulate an analytics query
    const analyticsQuery = `SELECT metadata->>'category' AS category, COUNT(*) FROM documents GROUP BY category`;
    const payload = JSON.stringify({ sql: analyticsQuery });

    let res = http.post('http://mosaic:4040/api/query', payload, params);
    check(res, { 'analytics query status is 200': (r) => r.status === 200 });
    queryTrend.add(res.timings.duration);
    errorRate.add(res.status !== 200);

    sleep(0.5);

    // Simulate explicit DuckDB analytics
    const duckdbQuery = `SELECT COUNT(*) FROM documents`;
    const duckdbPayload = JSON.stringify({ sql: duckdbQuery });
    res = http.post('http://mosaic:4040/api/analytics', duckdbPayload, params);
    check(res, { 'duckdb query status is 200': (r) => r.status === 200 });
    queryTrend.add(res.timings.duration);
    errorRate.add(res.status !== 200);
}

function adminScenario() {
    let res;

    res = http.get('http://mosaic:4040/api/shards');
    check(res, { 'get shards status is 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);

    sleep(0.1);

    res = http.post('http://mosaic:4040/api/admin/refresh-duckdb');
    check(res, { 'refresh duckdb status is 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);

    sleep(0.1);

    res = http.get('http://mosaic:4040/api/metrics');
    check(res, { 'get metrics status is 200': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
}
