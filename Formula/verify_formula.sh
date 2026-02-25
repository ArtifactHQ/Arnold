#!/bin/sh
# Verifies the Homebrew formula structure (does not require brew).
set -e

FORMULA="Formula/arnold.rb"

echo "Checking formula exists..."
test -f "$FORMULA" || { echo "FAIL: $FORMULA not found"; exit 1; }

echo "Checking Ruby syntax..."
ruby -c "$FORMULA" || { echo "FAIL: Ruby syntax error in $FORMULA"; exit 1; }

echo "Checking class definition..."
grep -q 'class Arnold < Formula' "$FORMULA" || { echo "FAIL: Missing class definition"; exit 1; }

echo "Checking desc..."
grep -q 'desc ' "$FORMULA" || { echo "FAIL: Missing desc"; exit 1; }

echo "Checking homepage..."
grep -q 'homepage ' "$FORMULA" || { echo "FAIL: Missing homepage"; exit 1; }

echo "Checking ruby dependency..."
grep -q 'depends_on "ruby"' "$FORMULA" || { echo "FAIL: Missing ruby dependency"; exit 1; }

echo "Checking sqlite3 dependency..."
grep -q 'depends_on "sqlite3"' "$FORMULA" || { echo "FAIL: Missing sqlite3 dependency"; exit 1; }

echo "Checking install method..."
grep -q 'def install' "$FORMULA" || { echo "FAIL: Missing install method"; exit 1; }

echo "Checking GEM_HOME isolation..."
grep -q 'GEM_HOME' "$FORMULA" || { echo "FAIL: Missing GEM_HOME setup"; exit 1; }

echo "Checking bundler install..."
grep -q 'bundle.*install' "$FORMULA" || { echo "FAIL: Missing bundle install"; exit 1; }

echo "Checking bin wrapper..."
grep -q 'bin/"arnold"' "$FORMULA" || { echo "FAIL: Missing bin wrapper"; exit 1; }

echo "Checking service block..."
grep -q 'service do' "$FORMULA" || { echo "FAIL: Missing service block"; exit 1; }

echo "Checking MCP command in service..."
grep -q '"mcp"' "$FORMULA" || { echo "FAIL: Service should run arnold mcp"; exit 1; }

echo "Checking test block..."
grep -q 'test do' "$FORMULA" || { echo "FAIL: Missing test block"; exit 1; }

echo "Checking version test assertion..."
grep -q 'arnold_pipeline' "$FORMULA" || { echo "FAIL: Missing version assertion"; exit 1; }

echo ""
echo "All formula checks passed!"
