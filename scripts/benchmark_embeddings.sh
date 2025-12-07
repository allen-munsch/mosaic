#!/bin/bash

# Benchmark batch indexing to measure actual embedding time
# Usage: ./benchmark_embeddings.sh [host] [num_docs]

HOST="${1:-http://localhost:4040}"
NUM_DOCS="${2:-50}"

echo "=== Embedding Benchmark ==="
echo "Host: $HOST"
echo "Documents: $NUM_DOCS"
echo ""

# Generate test documents
DOCS=""
for i in $(seq 1 $NUM_DOCS); do
  if [ -n "$DOCS" ]; then DOCS="$DOCS,"; fi
  DOCS="$DOCS{\"id\":\"bench_$i\",\"text\":\"This is benchmark document number $i with enough text to generate a meaningful embedding vector for performance testing purposes.\"}"
done

# Warm up
echo "Warming up..."
curl -s -X POST "$HOST/api/documents" -H "Content-Type: application/json" -d '{"documents":[{"id":"warmup","text":"warmup text"}]}' > /dev/null

# Benchmark batch indexing (synchronous)
echo "Running batch index benchmark..."
START=$(date +%s%3N)
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$HOST/api/documents" -H "Content-Type: application/json" -d "{\"documents\":[$DOCS]}")
END=$(date +%s%3N)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

DURATION=$((END - START))
PER_DOC=$((DURATION / NUM_DOCS))

echo ""
echo "=== Results ==="
echo "Total time: ${DURATION}ms"
echo "Per document: ${PER_DOC}ms"
echo "Throughput: $(echo "scale=2; $NUM_DOCS * 1000 / $DURATION" | bc) docs/sec"
echo "HTTP status: $HTTP_CODE"
echo "Response: $BODY"
