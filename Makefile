# ck-mlx Makefile — builds and installs the Swift CLI + MCP server.
#
# Usage:
#   make            # release build only
#   make install    # release build + install binaries to $(INSTALL_DIR)
#   make test       # run unit tests
#   make clean      # remove build artifacts
#   make uninstall  # remove installed binaries
#
# Override the install location:
#   make install INSTALL_DIR=/opt/homebrew/bin

INSTALL_DIR ?= $(HOME)/.local/bin
SWIFT      ?= swift
BINARIES   := ck-mlx ck-mlx-mcp
BUILDDIR   := .build/release

.PHONY: all build install test clean uninstall

all: build

build:
	$(SWIFT) build -c release

install: build
	@mkdir -p "$(INSTALL_DIR)"
	@for bin in $(BINARIES); do \
		install -m 0755 "$(BUILDDIR)/$$bin" "$(INSTALL_DIR)/$$bin"; \
		echo "installed $(INSTALL_DIR)/$$bin"; \
	done
	@echo ""
	@echo "ck-mlx and ck-mlx-mcp installed to $(INSTALL_DIR)"
	@echo "verify with: which ck-mlx && ck-mlx --help"
	@echo "MCP config (opencode.jsonc) — point 'command' at the installed path or just 'ck-mlx-mcp' if $(INSTALL_DIR) is on PATH"

test:
	$(SWIFT) test

clean:
	$(SWIFT) package clean
	rm -rf .build

uninstall:
	@for bin in $(BINARIES); do \
		rm -f "$(INSTALL_DIR)/$$bin"; \
		echo "removed $(INSTALL_DIR)/$$bin"; \
	done
