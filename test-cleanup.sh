#!/bin/bash
#
# Test script for cleanup-all.sh functionality
# Creates test data structure and validates cleanup behavior
#

set -e

# Test directory
TEST_ROOT="/tmp/outdoor-backup-test"
BACKUP_ROOT="$TEST_ROOT/SDMirrors"
CONF_DIR="$TEST_ROOT/conf"
SCRIPTS_DIR="$(cd "$(dirname "$0")/files/opt/outdoor-backup/scripts" && pwd)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
test_passed() {
	echo -e "${GREEN}✓ PASSED${NC}: $1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_failed() {
	echo -e "${RED}✗ FAILED${NC}: $1"
	TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_warning() {
	echo -e "${YELLOW}⚠ WARNING${NC}: $1"
}

# Setup test environment
setup_test_env() {
	echo "Setting up test environment..."

	# Clean previous test
	rm -rf "$TEST_ROOT"

	# Create directory structure
	mkdir -p "$BACKUP_ROOT/.logs"
	mkdir -p "$CONF_DIR"
	mkdir -p "$TEST_ROOT/log"  # For common.sh logging

	# Create test UUID directories with dummy data
	# Valid UUIDs
	mkdir -p "$BACKUP_ROOT/550e8400-e29b-41d4-a716-446655440000"
	dd if=/dev/zero of="$BACKUP_ROOT/550e8400-e29b-41d4-a716-446655440000/test1.dat" bs=1M count=10 2>/dev/null

	mkdir -p "$BACKUP_ROOT/7c9e6679-7425-40de-944b-e07fc1f90ae7"
	dd if=/dev/zero of="$BACKUP_ROOT/7c9e6679-7425-40de-944b-e07fc1f90ae7/test2.dat" bs=1M count=5 2>/dev/null

	mkdir -p "$BACKUP_ROOT/3b1e7a9f-8d6c-4c3e-b2f4-9a1e7d8c4b5a"
	dd if=/dev/zero of="$BACKUP_ROOT/3b1e7a9f-8d6c-4c3e-b2f4-9a1e7d8c4b5a/test3.dat" bs=1M count=8 2>/dev/null

	# Invalid directory names (should be skipped)
	mkdir -p "$BACKUP_ROOT/invalid-directory"
	echo "should not be deleted" > "$BACKUP_ROOT/invalid-directory/test.txt"

	mkdir -p "$BACKUP_ROOT/lost+found"
	echo "system directory" > "$BACKUP_ROOT/lost+found/test.txt"

	# Create aliases.json
	cat > "$CONF_DIR/aliases.json" << 'EOF'
{
  "version": "1.0",
  "aliases": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "alias": "Test Card 1",
      "notes": "First test card",
      "created_at": 1728825600,
      "last_seen": 1728825600
    },
    "7c9e6679-7425-40de-944b-e07fc1f90ae7": {
      "alias": "Test Card 2",
      "notes": "Second test card",
      "created_at": 1728800000,
      "last_seen": 1728900000
    }
  }
}
EOF

	echo "Test environment created at: $TEST_ROOT"
}

# Test 1: is_valid_uuid function
test_uuid_validation() {
	echo ""
	echo "=== Test 1: UUID Validation ==="

	# Source common.sh to get is_valid_uuid function
	. "$SCRIPTS_DIR/common.sh"

	# Valid UUIDs
	if is_valid_uuid "550e8400-e29b-41d4-a716-446655440000"; then
		test_passed "Valid UUID accepted (lowercase)"
	else
		test_failed "Valid UUID rejected (lowercase)"
	fi

	if is_valid_uuid "7C9E6679-7425-40DE-944B-E07FC1F90AE7"; then
		test_passed "Valid UUID accepted (uppercase)"
	else
		test_failed "Valid UUID rejected (uppercase)"
	fi

	# Invalid UUIDs
	if ! is_valid_uuid "not-a-uuid"; then
		test_passed "Invalid UUID rejected (short)"
	else
		test_failed "Invalid UUID accepted (short)"
	fi

	if ! is_valid_uuid "550e8400-e29b-41d4-a716-44665544000x"; then
		test_passed "Invalid UUID rejected (non-hex char)"
	else
		test_failed "Invalid UUID accepted (non-hex char)"
	fi

	if ! is_valid_uuid "550e8400-e29b-41d4-a716"; then
		test_passed "Invalid UUID rejected (too short)"
	else
		test_failed "Invalid UUID accepted (too short)"
	fi
}

# Test 2: get_total_backup_size function
test_total_size_calculation() {
	echo ""
	echo "=== Test 2: Total Size Calculation ==="

	. "$SCRIPTS_DIR/common.sh"

	local total_size=$(get_total_backup_size "$BACKUP_ROOT")

	# Expected: ~23MB + overhead (10+5+8 MB data files)
	if [ "$total_size" -gt 23000000 ] && [ "$total_size" -lt 30000000 ]; then
		test_passed "Total size calculated: $total_size bytes (~23MB)"
	else
		test_warning "Total size: $total_size bytes (expected ~23MB)"
	fi

	# Test non-existent directory
	local zero_size=$(get_total_backup_size "/non/existent/path")
	if [ "$zero_size" = "0" ]; then
		test_passed "Non-existent path returns 0"
	else
		test_failed "Non-existent path returns: $zero_size"
	fi
}

# Test 3: cleanup-all.sh execution with keep_aliases=1
test_cleanup_keep_aliases() {
	echo ""
	echo "=== Test 3: Cleanup with Aliases Preserved ==="

	# Copy scripts to test environment (needed because cleanup-all.sh sources common.sh)
	mkdir -p "$TEST_ROOT/scripts"
	cp "$SCRIPTS_DIR/common.sh" "$TEST_ROOT/scripts/"
	cp "$SCRIPTS_DIR/cleanup-all.sh" "$TEST_ROOT/scripts/"

	# Set BASE_DIR for testing
	export BASE_DIR="$TEST_ROOT"

	# Run cleanup script from test location
	bash "$TEST_ROOT/scripts/cleanup-all.sh" "$BACKUP_ROOT" 1

	# Check if UUID directories are empty
	local uuid1_files=$(find "$BACKUP_ROOT/550e8400-e29b-41d4-a716-446655440000" -type f 2>/dev/null | wc -l)
	if [ "$uuid1_files" -eq 0 ]; then
		test_passed "UUID directory 1 cleaned (0 files)"
	else
		test_failed "UUID directory 1 still has $uuid1_files files"
	fi

	local uuid2_files=$(find "$BACKUP_ROOT/7c9e6679-7425-40de-944b-e07fc1f90ae7" -type f 2>/dev/null | wc -l)
	if [ "$uuid2_files" -eq 0 ]; then
		test_passed "UUID directory 2 cleaned (0 files)"
	else
		test_failed "UUID directory 2 still has $uuid2_files files"
	fi

	# Check if UUID directories still exist (structure preserved)
	if [ -d "$BACKUP_ROOT/550e8400-e29b-41d4-a716-446655440000" ]; then
		test_passed "UUID directory 1 structure preserved"
	else
		test_failed "UUID directory 1 deleted (should be preserved)"
	fi

	# Check if invalid directories are untouched
	if [ -f "$BACKUP_ROOT/invalid-directory/test.txt" ]; then
		test_passed "Invalid directory preserved (not a UUID)"
	else
		test_failed "Invalid directory deleted (should be preserved)"
	fi

	if [ -f "$BACKUP_ROOT/lost+found/test.txt" ]; then
		test_passed "Special directory preserved (lost+found)"
	else
		test_failed "Special directory deleted (should be preserved)"
	fi

	# Check if aliases.json is preserved
	if [ -f "$CONF_DIR/aliases.json" ]; then
		local alias_count=$(grep -c '"alias"' "$CONF_DIR/aliases.json" 2>/dev/null || echo "0")
		if [ "$alias_count" -ge 2 ]; then
			test_passed "aliases.json preserved with $alias_count aliases"
		else
			test_failed "aliases.json exists but aliases cleared"
		fi
	else
		test_failed "aliases.json deleted (should be preserved)"
	fi
}

# Test 4: cleanup-all.sh execution with keep_aliases=0
test_cleanup_clear_aliases() {
	echo ""
	echo "=== Test 4: Cleanup with Aliases Cleared ==="

	# Recreate test data for second cleanup test
	setup_test_env

	# Copy scripts to test environment
	mkdir -p "$TEST_ROOT/scripts"
	cp "$SCRIPTS_DIR/common.sh" "$TEST_ROOT/scripts/"
	cp "$SCRIPTS_DIR/cleanup-all.sh" "$TEST_ROOT/scripts/"

	# Set BASE_DIR for testing
	export BASE_DIR="$TEST_ROOT"

	# Run cleanup script with keep_aliases=0
	bash "$TEST_ROOT/scripts/cleanup-all.sh" "$BACKUP_ROOT" 0

	# Check if aliases.json is cleared
	if [ -f "$CONF_DIR/aliases.json" ]; then
		local empty_aliases=$(grep -c '"aliases"[[:space:]]*:[[:space:]]*{}' "$CONF_DIR/aliases.json" 2>/dev/null || echo "0")
		if [ "$empty_aliases" -ge 1 ]; then
			test_passed "aliases.json cleared (empty aliases object)"
		else
			test_failed "aliases.json not properly cleared"
			cat "$CONF_DIR/aliases.json"
		fi
	else
		test_failed "aliases.json deleted (should exist but be cleared)"
	fi
}

# Test 5: Error handling
test_error_handling() {
	echo ""
	echo "=== Test 5: Error Handling ==="

	# Test missing argument
	if ! bash "$SCRIPTS_DIR/cleanup-all.sh" 2>/dev/null; then
		test_passed "Missing argument rejected"
	else
		test_failed "Missing argument accepted"
	fi

	# Test non-existent directory
	if ! bash "$SCRIPTS_DIR/cleanup-all.sh" "/non/existent/path" 2>/dev/null; then
		test_passed "Non-existent directory rejected"
	else
		test_failed "Non-existent directory accepted"
	fi

	# Test unsafe path (directory traversal attempt)
	if ! bash "$SCRIPTS_DIR/cleanup-all.sh" "/tmp/../etc" 2>/dev/null; then
		test_passed "Unsafe path rejected (directory traversal)"
	else
		test_failed "Unsafe path accepted (security issue!)"
	fi
}

# Main test execution
main() {
	echo "========================================"
	echo "  Outdoor Backup - Cleanup Test Suite"
	echo "========================================"

	setup_test_env
	test_uuid_validation
	test_total_size_calculation
	test_cleanup_keep_aliases
	test_cleanup_clear_aliases
	test_error_handling

	echo ""
	echo "========================================"
	echo "  Test Results"
	echo "========================================"
	echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
	echo -e "${RED}Failed: $TESTS_FAILED${NC}"

	# Cleanup test environment
	echo ""
	echo "Cleaning up test environment..."
	rm -rf "$TEST_ROOT"

	if [ $TESTS_FAILED -eq 0 ]; then
		echo -e "${GREEN}All tests passed!${NC}"
		exit 0
	else
		echo -e "${RED}Some tests failed.${NC}"
		exit 1
	fi
}

main "$@"
