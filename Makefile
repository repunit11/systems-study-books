# Typst Compilation Makefile using container engine (Podman/Docker)
# このMakefileはコンテナエンジン（Podman推奨、なければDocker）を使用してTypstファイルをPDFにコンパイルします

# Dockerイメージ
TYPST_IMAGE := ghcr.io/typst/typst:latest

# コンテナエンジン（デフォルトはPodman、無ければDocker）
CONTAINER ?= $(shell if command -v podman >/dev/null 2>&1; then echo podman; else echo docker; fi)

# SELinuxがEnforcingならワークディレクトリのみラベルを付与（システムフォントはラベルしない）
SELINUX_LABEL ?= $(shell if command -v getenforce >/dev/null 2>&1 && [ "$$(getenforce 2>/dev/null)" = "Enforcing" ]; then echo Z; fi)
WORK_OPTS :=
FONT_OPTS := ro
ifeq ($(SELINUX_LABEL),Z)
  WORK_OPTS := Z
endif
# 必要なら FONT_LABEL=Z などでフォント側にも任意オプションを付ける
ifneq ($(FONT_LABEL),)
  FONT_OPTS := $(FONT_OPTS),$(FONT_LABEL)
endif

# コンパイル対象
# - ルート直下の .typ
# - 各ドキュメントディレクトリの main.typ
# 部分ファイル（chapters/*.typ, theme.typ など）は build-all から除外する
TYPST_FILES := $(shell find . -maxdepth 1 -name "*.typ" -type f; find . -name "main.typ" -type f)
BOOK_FILE := compilerbook/main.typ
RUST_OS_BOOK_FILE := rust-os-book/main.typ

# システムフォントパス（Linuxの場合、複数指定可能）
FONT_DIR := /usr/share/fonts

# デフォルトターゲット
.PHONY: help
help:
	@echo "利用可能なコマンド:"
	@echo "  make build-all     - エントリポイントの.typファイルをまとめてコンパイル"
	@echo "  make build FILE=path/to/file.typ - 指定したファイルをコンパイル"
	@echo "  make book          - compilerbook を1つのPDFとしてコンパイル"
	@echo "  make watch-book    - compilerbook の変更を監視して自動コンパイル"
	@echo "  make rust-os-book  - rust-os-book を1つのPDFとしてコンパイル"
	@echo "  make watch-rust-os-book - rust-os-book の変更を監視して自動コンパイル"
	@echo "  make clean         - 生成されたPDFファイルを削除"
	@echo "  make watch FILE=path/to/file.typ - ファイルの変更を監視して自動コンパイル"
	@echo "  make fonts         - Typstで使用可能なフォント一覧を表示"
	@echo "  make fonts-system  - システムフォントを含むフォント一覧を表示"
	@echo "  make pull          - TypstのDockerイメージを最新版に更新"

# すべてのTypstファイルをコンパイル
.PHONY: build-all
build-all:
	@echo "すべてのTypstファイルをコンパイルしています..."
	@trap 'echo ""; echo "中断されました"; exit 130' INT TERM; \
	for typ_file in $(TYPST_FILES); do \
		echo "コンパイル中: $$typ_file"; \
		$(CONTAINER) run --rm --init \
			-v "$$(pwd):/work$(if $(WORK_OPTS),:$(WORK_OPTS))" \
			-v "$(FONT_DIR):/fonts$(if $(FONT_OPTS),:$(FONT_OPTS))" \
			-w /work \
			-e TYPST_FONT_PATHS="/fonts" \
			$(TYPST_IMAGE) \
			compile "$$typ_file" "$${typ_file%.typ}.pdf" || true; \
	done; \
	echo "コンパイル完了"

# compilerbook を1つのPDFとしてコンパイル
.PHONY: book
book:
	@$(MAKE) build FILE=$(BOOK_FILE)

# rust-os-book を1つのPDFとしてコンパイル
.PHONY: rust-os-book
rust-os-book:
	@$(MAKE) build FILE=$(RUST_OS_BOOK_FILE)

# 指定したファイルをコンパイル
.PHONY: build
build:
ifndef FILE
	@echo "エラー: FILEパラメータを指定してください"
	@echo "例: make build FILE=computerArchitecture/main.typ"
	@exit 1
endif
	@if [ ! -f "$(FILE)" ]; then \
		echo "エラー: ファイル $(FILE) が見つかりません"; \
		exit 1; \
	fi
	@echo "コンパイル中: $(FILE)"
	@$(CONTAINER) run --rm --init \
		-v "$$(pwd):/work$(if $(WORK_OPTS),:$(WORK_OPTS))" \
		-v "$(FONT_DIR):/fonts$(if $(FONT_OPTS),:$(FONT_OPTS))" \
		-w /work \
		-e TYPST_FONT_PATHS="/fonts" \
		$(TYPST_IMAGE) \
		compile "$(FILE)" "$(FILE:.typ=.pdf)"
	@echo "コンパイル完了: $(FILE:.typ=.pdf)"

# ファイルの変更を監視して自動コンパイル（watch mode）
.PHONY: watch
watch:
ifndef FILE
	@echo "エラー: FILEパラメータを指定してください"
	@echo "例: make watch FILE=computerArchitecture/main.typ"
	@exit 1
endif
	@if [ ! -f "$(FILE)" ]; then \
		echo "エラー: ファイル $(FILE) が見つかりません"; \
		exit 1; \
	fi
	@echo "監視モード: $(FILE) の変更を監視しています（Ctrl+Cで終了）"
	@$(CONTAINER) run --rm -it --init \
		-v "$$(pwd):/work$(if $(WORK_OPTS),:$(WORK_OPTS))" \
		-v "$(FONT_DIR):/fonts$(if $(FONT_OPTS),:$(FONT_OPTS))" \
		-w /work \
		-e TYPST_FONT_PATHS="/fonts" \
		$(TYPST_IMAGE) \
		watch "$(FILE)" "$(FILE:.typ=.pdf)"

# compilerbook の変更を監視して自動コンパイル
.PHONY: watch-book
watch-book:
	@$(MAKE) watch FILE=$(BOOK_FILE)

# rust-os-book の変更を監視して自動コンパイル
.PHONY: watch-rust-os-book
watch-rust-os-book:
	@$(MAKE) watch FILE=$(RUST_OS_BOOK_FILE)

# 生成されたPDFファイルを削除
.PHONY: clean
clean:
	@echo "PDFファイルを削除しています..."
	@find . -name "*.pdf" -type f -delete
	@echo "削除完了"

# Typstで使用可能なフォント一覧を表示
.PHONY: fonts
fonts:
	@echo "Typstで使用可能なフォント一覧:"
	@$(CONTAINER) run --rm --init \
		-v "$$(pwd):/work$(if $(WORK_OPTS),:$(WORK_OPTS))" \
		-w /work \
		$(TYPST_IMAGE) \
		fonts

# システムフォントを含むフォント一覧を表示
.PHONY: fonts-system
fonts-system:
	@echo "システムフォントを含むフォント一覧:"
	@$(CONTAINER) run --rm --init \
		-v "$$(pwd):/work$(if $(WORK_OPTS),:$(WORK_OPTS))" \
		-v "$(FONT_DIR):/fonts$(if $(FONT_OPTS),:$(FONT_OPTS))" \
		-w /work \
		-e TYPST_FONT_PATHS="/fonts" \
		$(TYPST_IMAGE) \
		fonts

# Dockerイメージを最新版に更新
.PHONY: pull
pull:
	@echo "TypstのDockerイメージを更新しています..."
	@$(CONTAINER) pull $(TYPST_IMAGE)
	@echo "更新完了"
