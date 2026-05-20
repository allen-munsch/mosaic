#!/bin/bash
# ============================================================================
# MosaicDB - Development Fix Script
# ============================================================================

set -e

echo "MosaicDB Development Fix"
echo "========================"
echo ""

cd "$(dirname "$0")/.."

# 1. Check Elixir/OTP
echo "Checking Elixir..."
if command -v elixir &>/dev/null; then
    elixir --version | head -1
else
    echo "  Elixir not found. Install from https://elixir-lang.org/install.html"
fi
echo ""

# 2. Fetch deps
echo "Fetching dependencies..."
mix deps.get 2>/dev/null || echo "  mix deps.get failed (check mix.exs)"
echo ""

# 3. Compile
echo "Compiling..."
mix compile --warnings-as-errors 2>&1 | tail -5 || echo "  Compile failed (check errors above)"
echo ""

# 4. Run tests
echo "Running tests..."
mix test 2>&1 | grep -E "tests,.*failures" || echo "  Tests failed (check output above)"
echo ""

# 5. Check port 4040
echo "Checking port 4040..."
if ss -tlnp | grep -q ":4040"; then
    echo "  Port 4040 is in use. Free it with: fuser -k 4040/tcp"
else
    echo "  Port 4040 is free"
fi
echo ""

# 6. Format check
echo "Checking code formatting..."
mix format --check-formatted 2>&1 || echo "  Code not formatted. Run: mix format"
echo ""

# 7. Clean temp files
echo "Cleaning build artifacts..."
rm -rf _build/test _build/dev 2>/dev/null || true
echo "  Cleaned _build cache"
echo ""

echo "Done. Run 'mix test' to verify everything works."
