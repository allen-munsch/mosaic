#!/bin/bash

# MosaicDB Demo Script
# Showcases semantic search, hybrid queries, analytics, and GPU-accelerated embeddings

HOST="${1:-http://localhost:4040}"
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m'

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
  echo -e "\n${YELLOW}▸${NC} ${BOLD}$1${NC}"
}

timed_request() {
  local start=$(date +%s%3N)
  local response=$(curl -s -w "\n%{http_code}" "$@")
  local end=$(date +%s%3N)
  local duration=$((end - start))
  local body=$(echo "$response" | head -n -1)
  local code=$(echo "$response" | tail -1)
  echo "$body" | jq . 2>/dev/null || echo "$body"
  echo -e "${GREEN}  ✓ ${duration}ms (HTTP ${code})${NC}"
}

cold_warm_search() {
  local query="$1"
  local label="$2"
  
  print_step "Query: '$label'"
  echo -e "${GRAY}  Demonstrating embedding cache effect...${NC}"
  
  # Cold run (generates embedding)
  local start1=$(date +%s%3N)
  local result=$(curl -s -X POST "$HOST/api/search" -H "Content-Type: application/json" -d "{\"query\": \"$query\", \"limit\": 2}")
  local end1=$(date +%s%3N)
  local cold=$((end1 - start1))
  
  # Hot run (cached embedding)
  local start2=$(date +%s%3N)
  curl -s -X POST "$HOST/api/search" -H "Content-Type: application/json" -d "{\"query\": \"$query\", \"limit\": 2}" > /dev/null
  local end2=$(date +%s%3N)
  local hot=$((end2 - start2))
  
  # Show results
  echo "$result" | jq -c '.results[:2] | .[] | {id, similarity: (.similarity * 100 | floor / 100), text: .text[:60]}' 2>/dev/null
  
  local speedup=$((cold / (hot + 1)))
  echo -e "  ${RED}COLD${NC} (embed + search): ${BOLD}${cold}ms${NC}"
  echo -e "  ${GREEN}HOT${NC}  (cached search):  ${BOLD}${hot}ms${NC} ${CYAN}(${speedup}x faster)${NC}"
}

cold_warm_hybrid() {
  local query="$1"
  local where="$2"
  local label="$3"
  
  print_step "Query: '$label'"
  echo -e "${GRAY}  Vector similarity + SQL filter...${NC}"
  
  local payload="{\"query\": \"$query\", \"where\": \"$where\", \"limit\": 2}"
  
  # Cold run
  local start1=$(date +%s%3N)
  local result=$(curl -s -X POST "$HOST/api/search/hybrid" -H "Content-Type: application/json" -d "$payload")
  local end1=$(date +%s%3N)
  local cold=$((end1 - start1))
  
  # Hot run
  local start2=$(date +%s%3N)
  curl -s -X POST "$HOST/api/search/hybrid" -H "Content-Type: application/json" -d "$payload" > /dev/null
  local end2=$(date +%s%3N)
  local hot=$((end2 - start2))
  
  echo "$result" | jq -c '.results[:2] | .[] | {id, similarity: (.similarity * 100 | floor / 100), category: .metadata.category}' 2>/dev/null
  
  local speedup=$((cold / (hot + 1)))
  echo -e "  ${RED}COLD${NC}: ${BOLD}${cold}ms${NC}  →  ${GREEN}HOT${NC}: ${BOLD}${hot}ms${NC} ${CYAN}(${speedup}x faster)${NC}"
}

clear
echo -e "${BOLD}${CYAN}"
cat << "EOF"
    __  ___                _      ____  ____ 
   /  |/  /___  _________ (_)____/ __ \/ __ )
  / /|_/ / __ \/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ / 
/_/  /_/\____/____/\__,_/_/\___/_____/_____/  
                                              
EOF
echo -e "${NC}"
echo -e "${BOLD}Federated Semantic Search + Analytics Engine${NC}"
echo -e "SQLite + sqlite-vec │ DuckDB │ Local GPU Embeddings"
echo ""
echo -e "${GRAY}Legend: ${RED}COLD${GRAY} = embedding generation + search${NC}"
echo -e "${GRAY}        ${GREEN}HOT${GRAY}  = cached embedding, search only${NC}"
sleep 2

# ============================================================================
print_header "1. SYSTEM STATUS"
# ============================================================================
print_step "Health check..."
timed_request "$HOST/health"

print_step "Current metrics..."
timed_request "$HOST/api/metrics"

# ============================================================================
print_header "2. DOCUMENT INGESTION (Batch Embedding)"
# ============================================================================
print_step "Indexing 10 product reviews with GPU-accelerated embeddings..."

DOCS='{"documents": [
  {"id": "prod_001", "text": "This wireless mechanical keyboard has incredible tactile feedback. Cherry MX Brown switches provide the perfect balance of typing feel and noise level. RGB backlighting is customizable.", "metadata": {"category": "electronics", "rating": 5, "price": 149.99}},
  {"id": "prod_002", "text": "Disappointed with battery life on this laptop. Barely lasts 4 hours. The display is gorgeous though - 4K OLED with vibrant colors. Performance is snappy with the M2 chip.", "metadata": {"category": "electronics", "rating": 3, "price": 1299.99}},
  {"id": "prod_003", "text": "Best espresso machine for home use. Pulls shots comparable to cafe quality. The steam wand takes practice but produces silky microfoam for latte art.", "metadata": {"category": "appliances", "rating": 5, "price": 699.99}},
  {"id": "prod_004", "text": "Running shoes with excellent cushioning for long distances. The carbon fiber plate gives noticeable energy return. Sizing runs small - order half size up.", "metadata": {"category": "sports", "rating": 4, "price": 249.99}},
  {"id": "prod_005", "text": "Noise cancelling headphones that rival the best. ANC blocks airplane engine noise completely. Sound signature is warm with punchy bass.", "metadata": {"category": "electronics", "rating": 5, "price": 379.99}},
  {"id": "book_001", "text": "A masterpiece of science fiction. The world-building is intricate and the political intrigue keeps you guessing. Dense prose rewards careful reading.", "metadata": {"category": "books", "rating": 5, "price": 24.99}},
  {"id": "book_002", "text": "Practical guide to machine learning with Python. Covers neural networks, transformers, and deployment. Code examples are clear and well-documented.", "metadata": {"category": "books", "rating": 4, "price": 49.99}},
  {"id": "food_001", "text": "Single-origin Ethiopian coffee with bright fruity notes. Hints of blueberry and dark chocolate. Best brewed as pour-over to appreciate the complexity.", "metadata": {"category": "food", "rating": 5, "price": 18.99}},
  {"id": "food_002", "text": "Artisanal hot sauce with smoky chipotle heat. Not just spicy - complex flavor with garlic and lime undertones. Perfect on tacos and eggs.", "metadata": {"category": "food", "rating": 4, "price": 12.99}},
  {"id": "home_001", "text": "Memory foam mattress that sleeps cool. Gel-infused layer prevents heat retention. Edge support could be better but comfort is exceptional.", "metadata": {"category": "home", "rating": 4, "price": 899.99}}
]}'

START=$(date +%s%3N)
RESULT=$(curl -s -X POST "$HOST/api/documents" -H "Content-Type: application/json" -d "$DOCS")
END=$(date +%s%3N)
INGEST_TIME=$((END - START))
INGEST_PER_DOC=$((INGEST_TIME / 10))

echo "$RESULT" | jq .
echo -e "${GREEN}  ✓ ${INGEST_TIME}ms total (${INGEST_PER_DOC}ms/doc for embedding + storage)${NC}"

# ============================================================================
print_header "3. SEMANTIC SEARCH - Cold vs Hot"
# ============================================================================
echo -e "\n${CYAN}Watch the speedup when embeddings are cached...${NC}"

cold_warm_search "comfortable for long work sessions" "comfortable for long work sessions"
cold_warm_search "good morning drink with complex taste" "good morning drink with complex taste"
cold_warm_search "high performance computing device" "high performance computing device"

# ============================================================================
print_header "4. HYBRID SEARCH - Vector + SQL Filter"
# ============================================================================
echo -e "\n${CYAN}Semantic similarity constrained by metadata...${NC}"

cold_warm_hybrid "premium quality worth the price" "json_extract(metadata, '\$.category') = 'electronics'" "premium quality WHERE category='electronics'"
cold_warm_hybrid "highly recommended must buy" "json_extract(metadata, '\$.rating') >= 5" "highly recommended WHERE rating >= 5"

# ============================================================================
print_header "5. ANALYTICS (DuckDB Warm Path)"
# ============================================================================
echo -e "\n${CYAN}Complex aggregations federated across shards...${NC}"

print_step "Document count"
timed_request -X POST "$HOST/api/analytics" -H "Content-Type: application/json" -d '{"sql": "SELECT COUNT(*) as total FROM documents"}'

print_step "Category breakdown"
timed_request -X POST "$HOST/api/analytics" -H "Content-Type: application/json" -d '{"sql": "SELECT json_extract(metadata, '\''$.category'\'') as cat, COUNT(*) as n FROM documents GROUP BY cat ORDER BY n DESC"}'

print_step "Price range by category"
timed_request -X POST "$HOST/api/analytics" -H "Content-Type: application/json" -d '{"sql": "SELECT json_extract(metadata, '\''$.category'\'') as cat, ROUND(AVG(CAST(json_extract(metadata, '\''$.price'\'') AS FLOAT)),2) as avg_price FROM documents GROUP BY cat"}'

# ============================================================================
print_header "6. SHARD TOPOLOGY"
# ============================================================================
print_step "Active shards..."
timed_request "$HOST/api/shards"

# ============================================================================
print_header "7. THROUGHPUT TEST - Cached Queries"
# ============================================================================
echo -e "\n${CYAN}10 parallel searches with warm cache...${NC}"

# Pre-warm all queries
QUERIES=("wireless audio" "caffeine beverage" "comfortable footwear" "learning programming" "kitchen appliance" "sleep quality" "spicy condiment" "portable computer" "science fiction" "typing experience")
echo -e "${GRAY}  Pre-warming cache...${NC}"
for q in "${QUERIES[@]}"; do
  curl -s -X POST "$HOST/api/search" -H "Content-Type: application/json" -d "{\"query\": \"$q\", \"limit\": 1}" > /dev/null
done

# Now time parallel execution
echo -e "${GRAY}  Running 10 parallel queries...${NC}"
START=$(date +%s%3N)
for q in "${QUERIES[@]}"; do
  curl -s -X POST "$HOST/api/search" -H "Content-Type: application/json" -d "{\"query\": \"$q\", \"limit\": 1}" > /dev/null &
done
wait
END=$(date +%s%3N)
TOTAL=$((END - START))
AVG=$((TOTAL / 10))

echo -e "  ${GREEN}✓ 10 queries in ${TOTAL}ms (${AVG}ms avg per query)${NC}"

# ============================================================================
print_header "8. FINAL METRICS"
# ============================================================================
print_step "Cache statistics..."
timed_request "$HOST/api/metrics"

echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}                         DEMO COMPLETE${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}MosaicDB Performance Profile:${NC}"
echo ""
echo -e "    ${RED}COLD${NC} query (embedding gen):  ~800-1500ms"
echo -e "    ${GREEN}HOT${NC}  query (cached):        ~2-15ms"
echo -e "    Analytics (DuckDB):       ~10-50ms"
echo -e "    Batch ingest:             ~${INGEST_PER_DOC}ms/doc"
echo ""
echo -e "  ${BOLD}Architecture:${NC}"
echo ""
echo -e "    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐"
echo -e "    │   Query     │───▶│  Embedding  │───▶│   Cache     │"
echo -e "    │             │    │  (GPU/CPU)  │    │   (ETS)     │"
echo -e "    └─────────────┘    └─────────────┘    └──────┬──────┘"
echo -e "                                                 │"
echo -e "         ┌───────────────────────────────────────┴───┐"
echo -e "         ▼                                           ▼"
echo -e "    ┌─────────────┐                          ┌─────────────┐"
echo -e "    │  sqlite-vec │  HOT PATH  (<15ms)       │   DuckDB    │"
echo -e "    │   (search)  │                          │ (analytics) │"
echo -e "    └─────────────┘                          └─────────────┘"
echo ""