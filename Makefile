# ATAK — Xcode gerektirmeyen build hattı
# swift build -> .app bundle -> ad-hoc imza -> çalıştır
#
# NOT: Hem derleme hem paketleme Desktop DIŞINDA yapılır.
# Desktop iCloud ile senkronlandığından dosya sağlayıcısı ürünlere sürekli
# `com.apple.FinderInfo` ekler ve codesign bunu reddeder:
#   "resource fork, Finder information, or similar detritus not allowed"
# xattr ile temizlemek yetmez — sağlayıcı saniyesinde geri ekler.

CONFIG      ?= debug
APP_NAME    := ATAK

WORK        := $(HOME)/Library/Developer/ATAK
SCRATCH     := $(WORK)/build
BUNDLE      := $(WORK)/$(APP_NAME).app
CONTENTS    := $(BUNDLE)/Contents

SWIFT       := swift
SWIFTFLAGS  := --scratch-path $(SCRATCH)
CONFIG_DIR   = $(shell printf '%s' "$(CONFIG)" | awk '{print toupper(substr($$0,1,1)) substr($$0,2)}')
BIN_PATH     = $(SCRATCH)/out/Products/$(CONFIG_DIR)

.PHONY: all build bundle sign run test smoke install uninstall clean where

all: bundle

# Derleme hatası ASLA yutulmaz: aksi hâlde `test -f` eski binary'yi görür ve
# bayat bir .app paketlenir. Çıktı loga alınır, hata varsa filtrelenip basılır.
build:
	@mkdir -p $(SCRATCH)
	@$(SWIFT) build -c $(CONFIG) $(SWIFTFLAGS) > $(SCRATCH)/build.log 2>&1 \
		|| ( grep -vE "ld: warning: search path" $(SCRATCH)/build.log \
		     | grep -E "error:" | head -30; \
		     echo "✗ Derleme başarısız"; exit 1 )
	@grep -vE "ld: warning: search path" $(SCRATCH)/build.log \
		| grep -E "warning:" | head -20 || true
	@test -f "$(BIN_PATH)/$(APP_NAME)" || (echo "✗ Çalıştırılabilir üretilmedi"; exit 1)

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp "$(BIN_PATH)/$(APP_NAME)" $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@if [ -d Resources/Assets ]; then cp -R Resources/Assets/. $(CONTENTS)/Resources/; fi
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@$(MAKE) -s sign
	@echo "✓ $(BUNDLE)"

sign:
	@codesign --force --sign - --timestamp=none \
		--entitlements Resources/ATAK.entitlements $(BUNDLE) 2>/dev/null \
		|| codesign --force --sign - $(BUNDLE)
	@codesign --verify --deep --strict $(BUNDLE) && echo "✓ imza doğrulandı"

run: bundle
	@open $(BUNDLE)

# Pencereyi açmadan başlatma sağlığını doğrular (veritabanı + FTS5 turu).
smoke: bundle
	@ATAK_SMOKE=1 $(CONTENTS)/MacOS/$(APP_NAME)

test:
	@$(SWIFT) test $(SWIFTFLAGS) 2>&1 | grep -vE "ld: warning: search path"

install: bundle
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(BUNDLE) /Applications/
	@codesign --verify --deep --strict /Applications/$(APP_NAME).app
	@echo "✓ /Applications/$(APP_NAME).app kuruldu"

uninstall:
	@rm -rf /Applications/$(APP_NAME).app
	@echo "✓ /Applications/$(APP_NAME).app kaldırıldı"

where:
	@echo "Uygulama    : $(BUNDLE)"
	@echo "Derleme     : $(SCRATCH)"
	@echo "Veritabanı  : $(HOME)/Library/Application Support/ATAK/atak.db"

clean:
	@rm -rf $(WORK) build
	@echo "✓ temizlendi"
