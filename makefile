FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
FRAMEWORK      = -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight -framework QuartzCore -framework IOSurface -framework CoreMedia -weak_framework ScreenCaptureKit -weak_framework AVFoundation
CLI_FLAGS      =
BUILD_FLAGS    = -std=c11 -Wall -Wextra -g -O0 -fvisibility=hidden -mmacosx-version-min=11.0 -fno-objc-arc -arch x86_64 -arch arm64 -sectcreate __TEXT __info_plist $(INFO_PLIST)
BUILD_PATH     = ./bin
DOC_PATH       = ./doc
SCRIPT_PATH    = ./scripts
ASSET_PATH     = ./assets
SMP_PATH       = ./examples
ARCH_PATH      = ./archive
OSAX_SRC       = ./src/osax/payload_bin.c ./src/osax/loader_bin.c
YABAI_SRC      = ./src/manifest.m $(OSAX_SRC)
OSAX_PATH      = ./src/osax
INFO_PLIST     = ./assets/Info.plist
BINS           = $(BUILD_PATH)/yabai

.PHONY: all asan tsan install man icon archive publish sign clean-build clean

all: clean-build $(BINS)

asan: BUILD_FLAGS=-std=c11 -Wall -Wextra -g -O0 -fvisibility=hidden -fsanitize=address,undefined -mmacosx-version-min=11.0 -fno-objc-arc -arch x86_64 -arch arm64 -sectcreate __TEXT __info_plist $(INFO_PLIST)
asan: clean-build $(BINS)

tsan: BUILD_FLAGS=-std=c11 -Wall -Wextra -g -O0 -fvisibility=hidden -fsanitize=thread,undefined -mmacosx-version-min=11.0 -fno-objc-arc -arch x86_64 -arch arm64 -sectcreate __TEXT __info_plist $(INFO_PLIST)
tsan: clean-build $(BINS)

install: BUILD_FLAGS=-std=c11 -Wall -Wextra -DNDEBUG -O3 -fvisibility=hidden -mmacosx-version-min=11.0 -fno-objc-arc -arch x86_64 -arch arm64 -sectcreate __TEXT __info_plist $(INFO_PLIST)
install: clean-build $(BINS)

PAYLOAD_INCS = $(wildcard $(OSAX_PATH)/payload_inc/*.inc.m) $(wildcard $(OSAX_PATH)/payload_inc/*/*.inc.m) $(wildcard $(OSAX_PATH)/payload_inc/*/*/*.inc.m)

# Git branch + short SHA of the tree this payload is built from, baked in so
# the dev log can name the loaded payload's provenance and a stale
# (not-rebuilt) payload is obvious. Empty (no git / tarball build) -> unknown/nogit.
PAYLOAD_BRANCH := $(shell git -C $(CURDIR) rev-parse --abbrev-ref HEAD 2>/dev/null)
ifeq ($(PAYLOAD_BRANCH),)
PAYLOAD_BRANCH := unknown
endif
PAYLOAD_SHA := $(shell git -C $(CURDIR) rev-parse --short HEAD 2>/dev/null)
ifeq ($(PAYLOAD_SHA),)
PAYLOAD_SHA := nogit
endif

# Log subfolder tag for the opt-in verbose file logs (/tmp/logs/yabai/<tag>/).
# Override per checkout (make YB_LOG_TREE=mytree) so parallel dev checkouts
# don't clobber each other's logs.
YB_LOG_TREE := yabai

PAYLOAD_EXTRA_FLAGS ?=

# Everything the payload TU includes outside payload_inc/ — editing the wire
# contract (opcodes, shared structs) must rebuild the embedded payload, or an
# incremental build ships a payload that disagrees with the daemon.
PAYLOAD_WIRE_DEPS = $(OSAX_PATH)/common.h $(OSAX_PATH)/common_experimental.h $(OSAX_PATH)/x64_payload.m $(OSAX_PATH)/arm64_payload.m ./src/pile_transform.h ./src/misc/hashtable.h ./src/misc/displaylink.h

$(OSAX_SRC): $(OSAX_PATH)/loader.m $(OSAX_PATH)/payload.m $(PAYLOAD_INCS) $(PAYLOAD_WIRE_DEPS)
	xcrun clang $(OSAX_PATH)/payload.m -shared -fPIC -O3 -mmacosx-version-min=11.0 -arch x86_64 -arch arm64e -o $(OSAX_PATH)/payload $(FRAMEWORK_PATH) -framework SkyLight -framework Foundation -framework Carbon -framework IOSurface -framework CoreVideo -DPAYLOAD_BRANCH='"$(PAYLOAD_BRANCH)"' -DPAYLOAD_SHA='"$(PAYLOAD_SHA)"' -DYB_LOG_TREE='"$(YB_LOG_TREE)"' $(PAYLOAD_EXTRA_FLAGS)
	xcrun clang $(OSAX_PATH)/loader.m -O3 -mmacosx-version-min=11.0 -arch x86_64 -arch arm64e -o $(OSAX_PATH)/loader -framework Cocoa
	xxd -i -a $(OSAX_PATH)/payload $(OSAX_PATH)/payload_bin.c
	xxd -i -a $(OSAX_PATH)/loader $(OSAX_PATH)/loader_bin.c
	rm -f $(OSAX_PATH)/payload
	rm -f $(OSAX_PATH)/loader

man:
	asciidoctor -b manpage $(DOC_PATH)/yabai.asciidoc -o $(DOC_PATH)/yabai.1

icon:
	python3 $(SCRIPT_PATH)/seticon.py $(ASSET_PATH)/icon/2x/icon-512px@2x.png $(BUILD_PATH)/yabai

publish:
	sed -i '' "60s/^VERSION=.*/VERSION=\"$(shell $(BUILD_PATH)/yabai --version | cut -d "v" -f 2)\"/" $(SCRIPT_PATH)/install.sh
	sed -i '' "61s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shell shasum -a 256 $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz | cut -d " " -f 1)\"/" $(SCRIPT_PATH)/install.sh

archive: man install sign icon
	rm -rf $(ARCH_PATH)
	mkdir -p $(ARCH_PATH)
	cp -r $(BUILD_PATH) $(ARCH_PATH)/
	cp -r $(DOC_PATH) $(ARCH_PATH)/
	cp -r $(SMP_PATH) $(ARCH_PATH)/
	tar -cvzf $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz $(ARCH_PATH)
	rm -rf $(ARCH_PATH)

sign:
	codesign -fs "yabai-cert" $(BUILD_PATH)/yabai

clean-build:
	rm -rf $(BUILD_PATH)

clean: clean-build
	rm -f $(OSAX_SRC)

$(BUILD_PATH)/yabai: $(YABAI_SRC)
	mkdir -p $(BUILD_PATH)
	xcrun clang $^ $(BUILD_FLAGS) -DYB_LOG_TREE='"$(YB_LOG_TREE)"' $(FRAMEWORK_PATH) $(FRAMEWORK) $(CLI_FLAGS) -o $@

