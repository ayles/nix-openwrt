# Dump resolved compile dependencies from OpenWrt's .packagedeps
#
# Run from the OpenWrt source root after `make defconfig`:
#   make -f <this-file> __dump 2>/dev/null > resolved_deps.txt
#
# Output (on stderr, captured via 2>&1 or Make's $(info)):
#   DEPS:<dir>:<space-separated compile deps>
#   SELECTED:<dir>
#
# The $(if ...) guards in .packagedeps are evaluated against .config,
# so only deps matching the active configuration are emitted.

include .config

curdir := package
-include tmp/.packagedeps

base_dirs    := $(sort $(package-) $(package-y) $(package-m))
host_dirs    := $(foreach d,$(base_dirs),$(if $(buildtypes-$(d)),$(d)/$(buildtypes-$(d))))
all_dirs     := $(sort $(base_dirs) $(host_dirs))
selected_dirs := $(sort $(package-y) $(package-m))

$(foreach d,$(all_dirs),\
  $(if $($(curdir)/$(d)/compile),\
    $(info DEPS:$(d):$(patsubst $(curdir)/%/compile,%,$($(curdir)/$(d)/compile)))))

$(foreach d,$(selected_dirs),$(info SELECTED:$(d)))

.PHONY: __dump
__dump: ;@true
