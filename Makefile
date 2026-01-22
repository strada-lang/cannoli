# Cannoli - Preforking Web Server & Framework for Strada
#
# Build: make
# Test:  make test
# Clean: make clean
#
# Requires Strada to be installed (run 'make install' in strada directory)

STRADA := strada

SRC_DIR := src
LIB_DIR := lib
BUILD_DIR := build

# Source files in order of dependency
# Note: cannoli_obj.strada must come before router.strada (router calls Cannoli::new)
# Note: compress.strada has 'package compress;' so must come LAST (affects subsequent code)
SOURCES := \
	$(SRC_DIR)/config.strada \
	$(SRC_DIR)/mime.strada \
	$(SRC_DIR)/session.strada \
	$(SRC_DIR)/template.strada \
	$(SRC_DIR)/validation.strada \
	$(SRC_DIR)/request.strada \
	$(SRC_DIR)/log.strada \
	$(SRC_DIR)/response.strada \
	$(SRC_DIR)/cannoli_obj.strada \
	$(SRC_DIR)/router.strada \
	$(SRC_DIR)/static.strada \
	$(SRC_DIR)/server.strada \
	$(SRC_DIR)/fastcgi.strada \
	$(SRC_DIR)/app.strada \
	$(SRC_DIR)/main.strada \
	$(LIB_DIR)/compress.strada

# Combined source file
COMBINED := $(BUILD_DIR)/cannoli.strada

# Target binary
TARGET := cannoli

.PHONY: all clean test examples

all: $(TARGET)
	@echo ""
	@echo "✓ Built: ./$(TARGET)"
	@echo ""
	@echo "Run './$(TARGET) --help' for usage information"

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Combine all source files
$(COMBINED): $(SOURCES) | $(BUILD_DIR)
	@echo "Combining source files..."
	@cat $(SOURCES) > $(COMBINED)

# Build the binary using strada wrapper
$(TARGET): $(COMBINED)
	@echo "Compiling..."
	@$(STRADA) -l z $(COMBINED) -o $(TARGET)

# Run tests
test: $(TARGET)
	@chmod +x t/run_tests.sh build_test.sh
	@./t/run_tests.sh

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f $(TARGET)
	rm -f /tmp/cannoli_*

# Install to /usr/local/bin
install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/

# Development: run with auto-reload
dev: $(TARGET)
	./$(TARGET) --dev

# Help
help:
	@echo "Cannoli - Preforking Web Server & Framework for Strada"
	@echo ""
	@echo "Targets:"
	@echo "  make          - Build the cannoli binary"
	@echo "  make test     - Run the test suite"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make install  - Install to /usr/local/bin"
	@echo "  make dev      - Run in development mode"
	@echo ""
	@echo "Requires: Strada installed (strada command in PATH)"
	@echo ""
	@echo "After building, run: ./cannoli --help"
