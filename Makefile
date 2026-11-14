# 呼鈴（yobirin）
#
#   make build     Release ビルド（Apple Development 証明書で署名）→ build/Build/Products/Release/Yobirin.app
#   make install   ~/Applications/呼鈴.app へ入れ直して起動する
#   make test      ユニットテスト（YobirinCore）。テストだけは ad-hoc 署名で回す
#   make generate  project.yml から yobirin.xcodeproj を作る（各ターゲットが先に呼ぶ）
#
# ⚠️ アクセシビリティの許可は署名が変わると外れる。毎回同じ Apple Development 証明書で署名する。
#    ad-hoc（"-"）にはしない。証明書はキーチェーンにある最初の Apple Development を使う

APP_NAME        := 呼鈴
PROJECT         := yobirin.xcodeproj
SCHEME          := Yobirin
BUILD_DIR       := build
APP             := $(BUILD_DIR)/Build/Products/Release/Yobirin.app
INSTALL_APP_DIR := $(HOME)/Applications
INSTALLED       := $(INSTALL_APP_DIR)/$(APP_NAME).app
SIGN_NAME       ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)

.PHONY: build install uninstall test generate clean

generate:
	/opt/homebrew/bin/xcodegen generate --quiet

build: generate
	@test -n "$(SIGN_NAME)" || { echo "Apple Development 証明書が見つかりません（ad-hoc では作りません）"; exit 1; }
	@echo "署名: $(SIGN_NAME)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination "generic/platform=macOS" -derivedDataPath $(BUILD_DIR) CODE_SIGN_IDENTITY="$(SIGN_NAME)" build -quiet
	codesign --verify --deep --strict --verbose=1 $(APP)

install: build
	-osascript -e 'tell application id "jp.kechiiiiin.yobirin" to quit' 2>/dev/null
	mkdir -p "$(INSTALL_APP_DIR)"
	rm -rf "$(INSTALLED)"
	ditto $(APP) "$(INSTALLED)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALLED)"
	open "$(INSTALLED)"
	@echo "入れました: $(INSTALLED)"

uninstall:
	-osascript -e 'tell application id "jp.kechiiiiin.yobirin" to quit' 2>/dev/null
	rm -rf "$(INSTALLED)"
	@echo "設定（~/.config/yobirin）と履歴（~/Library/Application Support/yobirin）は残しています"

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -derivedDataPath $(BUILD_DIR)/test CODE_SIGN_IDENTITY=- \
	  -destination 'platform=macOS' test

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)
