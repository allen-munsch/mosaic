#!/bin/bash
# MosaicDB Interactive Demo Runner
# Data-driven demo showcasing semantic search, hybrid queries, multi-level retrieval, and analytics

set -e

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="${SCRIPT_DIR}/demo_data.json"
HOST="${MOSAIC_HOST:-http://localhost:4040}"
VERBOSE="${VERBOSE:-false}"
INTERACTIVE="${INTERACTIVE:-true}"
DEMO_SPEED="${DEMO_SPEED:-normal}"  # fast, normal, slow

# =============================================================================
# Colors and Formatting
# =============================================================================
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'
UNDERLINE='\033[4m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

# Box drawing characters
BOX_TL="╭"
BOX_TR="╮"
BOX_BL="╰"
BOX_BR="╯"
BOX_H="─"
BOX_V="│"
BOX_T="┬"
BOX_B="┴"
BOX_L="├"
BOX_R="┤"
BOX_X="┼"

# =============================================================================
# Utility Functions
# =============================================================================
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${GRAY}[DEBUG] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

pause_for_effect() {
    case "$DEMO_SPEED" in
        fast) sleep 0.5 ;;
        slow) sleep 3 ;;
        *) sleep 1.5 ;;
    esac
}

wait_for_key() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "\n${DIM}Press any key to continue...${NC}"
        read -n 1 -s
    fi
}

check_dependencies() {
    local missing=()
    command -v curl >/dev/null || missing+=("curl")
    command -v jq >/dev/null || missing+=("jq")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
    
    if [[ ! -f "$DATA_FILE" ]]; then
        log_error "Demo data file not found: $DATA_FILE"
        exit 1
    fi
}

check_server() {
    echo -e "${GRAY}Checking server at ${HOST}...${NC}"
    if ! curl -s --connect-timeout 5 "$HOST/health" >/dev/null 2>&1; then
        log_error "Cannot connect to MosaicDB at $HOST"
        echo -e "${YELLOW}Start the server with: mix phx.server${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Server is running${NC}\n"
}

# =============================================================================
# Display Functions
# =============================================================================
print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << "EOF"
    ╔╦╗┌─┐┌─┐┌─┐┬┌─┐╔╦╗╔╗ 
    ║║║│ │└─┐├─┤││  ║ ║╠╩╗
    ╩ ╩└─┘└─┘┴ ┴┴└─┘╚╩╝╚═╝
EOF
    echo -e "${NC}"
    echo -e "${BOLD}Federated Semantic Search Engine${NC}"
    echo -e "${DIM}SQLite + sqlite-vec │ Hierarchical Chunking │ Local Embeddings${NC}"
    echo ""
}

print_section() {
    local title="$1"
    local width=76
    local padding=$(( (width - ${#title} - 2) / 2 ))
    
    echo ""
    echo -e "${BOLD}${BLUE}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_TR}${NC}"
    echo -e "${BOLD}${BLUE}${BOX_V}${NC}$(printf '%*s' $padding '')${BOLD}${WHITE} $title ${NC}$(printf '%*s' $((width - padding - ${#title} - 2)) '')${BOLD}${BLUE}${BOX_V}${NC}"
    echo -e "${BOLD}${BLUE}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
    echo ""
}

print_subsection() {
    echo -e "\n${YELLOW}▸${NC} ${BOLD}$1${NC}"
}

print_explanation() {
    echo -e "${DIM}  $1${NC}"
}

print_query() {
    echo -e "${CYAN}  Query: ${WHITE}\"$1\"${NC}"
}

print_timing() {
    local cold="$1"
    local hot="$2"
    local speedup=$((cold / (hot + 1)))
    echo -e "  ${RED}COLD${NC} (embed + search): ${BOLD}${cold}ms${NC}"
    echo -e "  ${GREEN}HOT${NC}  (cached):         ${BOLD}${hot}ms${NC} ${CYAN}(${speedup}x faster)${NC}"
}

print_results_compact() {
    local results="$1"
    local max_items="${2:-3}"
    
    echo "$results" | jq -r --arg max "$max_items" '
        .results[:($max | tonumber)] | to_entries[] | 
        "  \(.index + 1). [\(.value.similarity | . * 100 | floor / 100)] \(.value.id // .value.doc_id) - \(.value.text[:60])..."
    ' 2>/dev/null || echo -e "  ${DIM}No results${NC}"
}

print_json_result() {
    local result="$1"
    echo "$result" | jq -C '.' 2>/dev/null || echo "$result"
}

# =============================================================================
# API Functions
# =============================================================================
timed_request() {
    local start end duration response body code
    start=$(date +%s%3N)
    response=$(curl -s -w "\n%{http_code}" "$@")
    end=$(date +%s%3N)
    duration=$((end - start))
    body=$(echo "$response" | head -n -1)
    code=$(echo "$response" | tail -1)
    
    echo "$body"
    echo -e "${GREEN}  ✓ ${duration}ms (HTTP ${code})${NC}" >&2
}

api_health() {
    curl -s "$HOST/health" | jq -C '.'
}

api_metrics() {
    curl -s "$HOST/api/metrics" | jq -C '.'
}

api_shards() {
    curl -s "$HOST/api/shards" | jq -C '.'
}

api_ingest() {
    local docs="$1"
    curl -s -X POST "$HOST/api/documents" \
        -H "Content-Type: application/json" \
        -d "$docs"
}

api_search() {
    local query="$1"
    local limit="${2:-5}"
    local level="${3:-paragraph}"
    
    curl -s -X POST "$HOST/api/search" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"$query\", \"limit\": $limit, \"level\": \"$level\"}"
}

api_search_grounded() {
    local query="$1"
    local limit="${2:-3}"
    
    curl -s -X POST "$HOST/api/search/grounded" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"$query\", \"limit\": $limit, \"expand_context\": true}"
}

api_hybrid_search() {
    local query="$1"
    local where="$2"
    local limit="${3:-5}"
    
    curl -s -X POST "$HOST/api/search/hybrid" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"$query\", \"where\": \"$where\", \"limit\": $limit}"
}

api_analytics() {
    local sql="$1"
    curl -s -X POST "$HOST/api/analytics" \
        -H "Content-Type: application/json" \
        -d "{\"sql\": \"$sql\"}"
}

cold_warm_search() {
    local query="$1"
    local limit="${2:-3}"
    
    # Cold run
    local start1=$(date +%s%3N)
    local result=$(api_search "$query" "$limit")
    local end1=$(date +%s%3N)
    local cold=$((end1 - start1))
    
    # Hot run
    local start2=$(date +%s%3N)
    api_search "$query" "$limit" >/dev/null
    local end2=$(date +%s%3N)
    local hot=$((end2 - start2))
    
    echo "$result"
    print_timing "$cold" "$hot" >&2
}

# =============================================================================
# Demo Sections
# =============================================================================
demo_ingest_dataset() {
    local dataset_key="$1"
    local dataset_name=$(jq -r ".datasets.${dataset_key}.description" "$DATA_FILE")
    local docs=$(jq -c "{documents: .datasets.${dataset_key}.documents}" "$DATA_FILE")
    local doc_count=$(echo "$docs" | jq '.documents | length')
    
    print_subsection "Loading: $dataset_name ($doc_count documents)"
    
    local start=$(date +%s%3N)
    local result=$(api_ingest "$docs")
    local end=$(date +%s%3N)
    local total=$((end - start))
    local per_doc=$((total / doc_count))
    
    echo "$result" | jq -C '.'
    echo -e "${GREEN}  ✓ ${total}ms total (${per_doc}ms/doc for embedding + indexing)${NC}"
}

demo_semantic_search() {
    print_section "SEMANTIC SEARCH"
    echo -e "${DIM}MosaicDB understands meaning, not just keywords.${NC}"
    echo -e "${DIM}Watch how queries match semantically related content.${NC}"
    
    local queries=$(jq -c '.demo_scenarios.semantic_search.queries[]' "$DATA_FILE")
    
    while IFS= read -r q; do
        local query=$(echo "$q" | jq -r '.query')
        local explanation=$(echo "$q" | jq -r '.explanation')
        
        print_subsection "$explanation"
        print_query "$query"
        
        local result=$(cold_warm_search "$query" 2)
        print_results_compact "$result" 2
        
        pause_for_effect
    done <<< "$queries"
}

demo_hybrid_search() {
    print_section "HYBRID SEARCH"
    echo -e "${DIM}Combine semantic similarity with SQL-style filters.${NC}"
    echo -e "${DIM}Best of both worlds: meaning + precision.${NC}"
    
    local queries=$(jq -c '.demo_scenarios.hybrid_search.queries[]' "$DATA_FILE")
    
    while IFS= read -r q; do
        local query=$(echo "$q" | jq -r '.query')
        local where=$(echo "$q" | jq -r '.where')
        local explanation=$(echo "$q" | jq -r '.explanation')
        
        print_subsection "$explanation"
        print_query "$query"
        echo -e "${MAGENTA}  Filter: ${WHITE}$where${NC}"
        
        local start=$(date +%s%3N)
        local result=$(api_hybrid_search "$query" "$where" 3)
        local end=$(date +%s%3N)
        
        print_results_compact "$result" 2
        echo -e "${GREEN}  ✓ $((end - start))ms${NC}"
        
        pause_for_effect
    done <<< "$queries"
}

demo_multi_level() {
    print_section "MULTI-LEVEL RETRIEVAL"
    echo -e "${DIM}Hierarchical chunking: document → paragraph → sentence${NC}"
    echo -e "${DIM}Same query, different granularity levels.${NC}"
    
    local queries=$(jq -c '.demo_scenarios.multi_level_retrieval.queries[]' "$DATA_FILE")
    local prev_query=""
    
    while IFS= read -r q; do
        local query=$(echo "$q" | jq -r '.query')
        local level=$(echo "$q" | jq -r '.level')
        local explanation=$(echo "$q" | jq -r '.explanation')
        
        if [[ "$query" != "$prev_query" ]]; then
            print_query "$query"
            prev_query="$query"
        fi
        
        echo -e "\n  ${YELLOW}Level: ${WHITE}$level${NC} - ${DIM}$explanation${NC}"
        
        local result=$(api_search "$query" 2 "$level")
        echo "$result" | jq -r '
            .results[:2][] | 
            "    → [\(.level)] \(.text[:70])..."
        ' 2>/dev/null
        
        pause_for_effect
    done <<< "$queries"
}

demo_grounded_search() {
    print_section "GROUNDED SEARCH (Provenance)"
    echo -e "${DIM}Track exactly where information comes from.${NC}"
    echo -e "${DIM}Essential for RAG applications and citations.${NC}"
    
    local queries=$(jq -c '.demo_scenarios.grounded_search.queries[]' "$DATA_FILE")
    
    while IFS= read -r q; do
        local query=$(echo "$q" | jq -r '.query')
        local explanation=$(echo "$q" | jq -r '.explanation')
        
        print_subsection "$explanation"
        print_query "$query"
        
        local result=$(api_search_grounded "$query" 1)
        
        echo "$result" | jq -C '
            .results[0] | {
                chunk_id: .id,
                doc_id: .doc_id,
                level: .level,
                text: .text[:80],
                grounding: {
                    start_offset: .grounding.start_offset,
                    end_offset: .grounding.end_offset,
                    parent_context: (.grounding.parent_context.text[:50] // null)
                }
            }
        ' 2>/dev/null
        
        pause_for_effect
    done <<< "$queries"
}

demo_analytics() {
    print_section "ANALYTICS (DuckDB)"
    echo -e "${DIM}Complex SQL aggregations across federated shards.${NC}"
    echo -e "${DIM}OLAP-style queries on your document corpus.${NC}"
    
    local queries=$(jq -c '.demo_scenarios.analytics.queries[]' "$DATA_FILE")
    
    while IFS= read -r q; do
        local sql=$(echo "$q" | jq -r '.sql')
        local explanation=$(echo "$q" | jq -r '.explanation')
        
        print_subsection "$explanation"
        echo -e "${DIM}  SQL: ${sql:0:60}...${NC}"
        
        local start=$(date +%s%3N)
        local result=$(api_analytics "$sql")
        local end=$(date +%s%3N)
        
        echo "$result" | jq -C '.results'
        echo -e "${GREEN}  ✓ $((end - start))ms${NC}"
        
        pause_for_effect
    done <<< "$queries"
}

demo_performance() {
    print_section "PERFORMANCE BENCHMARKS"
    
    print_subsection "Cold vs Hot Query Latency"
    echo -e "${DIM}First query generates embedding; subsequent queries use cache.${NC}"
    
    local queries=$(jq -r '.performance_tests.cold_vs_hot.queries[]' "$DATA_FILE")
    
    while IFS= read -r query; do
        print_query "$query"
        cold_warm_search "$query" 3 >/dev/null
        echo ""
    done <<< "$queries"
    
    print_subsection "Parallel Throughput Test"
    local parallel_count=$(jq -r '.performance_tests.throughput.parallel_queries' "$DATA_FILE")
    local throughput_queries=$(jq -r '.performance_tests.throughput.queries[]' "$DATA_FILE" | head -n "$parallel_count")
    
    echo -e "${DIM}Pre-warming cache...${NC}"
    while IFS= read -r q; do
        api_search "$q" 1 >/dev/null &
    done <<< "$throughput_queries"
    wait
    
    echo -e "${DIM}Running $parallel_count parallel queries...${NC}"
    local start=$(date +%s%3N)
    while IFS= read -r q; do
        api_search "$q" 1 >/dev/null &
    done <<< "$throughput_queries"
    wait
    local end=$(date +%s%3N)
    
    local total=$((end - start))
    local avg=$((total / parallel_count))
    local qps=$((parallel_count * 1000 / total))
    
    echo -e "${GREEN}  ✓ $parallel_count queries in ${total}ms${NC}"
    echo -e "${GREEN}    Average: ${avg}ms/query | Throughput: ${qps} QPS${NC}"
}

demo_topology() {
    print_section "SHARD TOPOLOGY"
    echo -e "${DIM}View active shards and their metadata.${NC}"
    
    api_shards
}

# =============================================================================
# Main Demo Sequences
# =============================================================================
run_full_demo() {
    print_banner
    check_dependencies
    check_server
    
    wait_for_key
    
    # Ingest all datasets
    print_section "DATA INGESTION"
    echo -e "${DIM}Loading multiple document types with GPU-accelerated embeddings...${NC}"
    
    for dataset in product_reviews technical_docs research_papers recipes; do
        demo_ingest_dataset "$dataset"
        pause_for_effect
    done
    
    wait_for_key
    
    # Run demo scenarios
    demo_semantic_search
    wait_for_key
    
    demo_hybrid_search
    wait_for_key
    
    demo_multi_level
    wait_for_key
    
    demo_grounded_search
    wait_for_key
    
    demo_analytics
    wait_for_key
    
    demo_performance
    wait_for_key
    
    demo_topology
    
    # Final summary
    print_section "DEMO COMPLETE"
    api_metrics
    
    echo ""
    echo -e "${BOLD}MosaicDB Feature Summary:${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Semantic search with local embeddings"
    echo -e "  ${GREEN}✓${NC} Hybrid search (vector + SQL filters)"
    echo -e "  ${GREEN}✓${NC} Multi-level retrieval (doc/para/sentence)"
    echo -e "  ${GREEN}✓${NC} Provenance tracking with grounding"
    echo -e "  ${GREEN}✓${NC} DuckDB analytics across shards"
    echo -e "  ${GREEN}✓${NC} Embedding cache for <15ms hot queries"
    echo ""
}

run_quick_demo() {
    print_banner
    check_dependencies
    check_server
    
    DEMO_SPEED="fast"
    INTERACTIVE="false"
    
    print_section "QUICK DEMO"
    
    demo_ingest_dataset "product_reviews"
    demo_ingest_dataset "technical_docs"
    
    # Just a few searches
    print_subsection "Sample Semantic Search"
    cold_warm_search "comfortable typing experience" 2
    print_results_compact "$(api_search 'comfortable typing experience' 2)" 2
    
    print_subsection "Sample Hybrid Search"
    local result=$(api_hybrid_search "highly recommended" "json_extract(metadata, '\$.rating') >= 4" 2)
    print_results_compact "$result" 2
    
    print_subsection "Sample Analytics"
    api_analytics "SELECT COUNT(*) as total FROM documents" | jq -C '.results'
    
    print_section "QUICK DEMO COMPLETE"
}

run_benchmark() {
    print_banner
    check_dependencies
    check_server
    
    INTERACTIVE="false"
    
    print_section "BENCHMARK MODE"
    
    # Ensure data is loaded
    for dataset in product_reviews technical_docs; do
        demo_ingest_dataset "$dataset"
    done
    
    demo_performance
    
    print_section "BENCHMARK COMPLETE"
}

# =============================================================================
# CLI Interface
# =============================================================================
show_help() {
    echo "MosaicDB Demo Runner"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  full        Run complete interactive demo (default)"
    echo "  quick       Run abbreviated demo"
    echo "  benchmark   Run performance benchmarks only"
    echo "  ingest      Load all demo datasets"
    echo "  search      Run semantic search demos"
    echo "  hybrid      Run hybrid search demos"
    echo "  analytics   Run analytics demos"
    echo "  help        Show this help"
    echo ""
    echo "Options:"
    echo "  --host URL      Server URL (default: http://localhost:4040)"
    echo "  --fast          Speed up demo transitions"
    echo "  --slow          Slow down demo transitions"
    echo "  --no-interactive  Don't wait for keypress"
    echo "  --verbose       Show debug output"
    echo ""
    echo "Environment:"
    echo "  MOSAIC_HOST     Server URL"
    echo "  DEMO_SPEED      fast|normal|slow"
    echo "  INTERACTIVE     true|false"
    echo "  VERBOSE         true|false"
}

# Parse arguments
COMMAND="${1:-full}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --fast) DEMO_SPEED="fast"; shift ;;
        --slow) DEMO_SPEED="slow"; shift ;;
        --no-interactive) INTERACTIVE="false"; shift ;;
        --verbose) VERBOSE="true"; shift ;;
        full|quick|benchmark|ingest|search|hybrid|analytics|help) COMMAND="$1"; shift ;;
        *) shift ;;
    esac
done

# Run command
case "$COMMAND" in
    full) run_full_demo ;;
    quick) run_quick_demo ;;
    benchmark) run_benchmark ;;
    ingest)
        check_dependencies && check_server
        print_section "DATA INGESTION"
        for dataset in product_reviews technical_docs research_papers recipes; do
            demo_ingest_dataset "$dataset"
        done
        ;;
    search)
        check_dependencies && check_server
        demo_semantic_search
        ;;
    hybrid)
        check_dependencies && check_server
        demo_hybrid_search
        ;;
    analytics)
        check_dependencies && check_server
        demo_analytics
        ;;
    help) show_help ;;
    *) show_help; exit 1 ;;
esac
