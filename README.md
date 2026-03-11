# Low-Level Study Books

Typst で管理している低レイヤ学習教材のリポジトリです。現在は以下の 9 冊を収録しています。

- `compilerbook`
  Rui Ueyama 氏の公開記事 `compilerbook` をもとに再構成し、未完部分も補った C コンパイラ学習ノート
- `rust-os-book`
  Philipp Oppermann 氏の `Writing an OS in Rust` と `rust-osdev` 周辺の公開OSSをもとに再構成した Rust OS 入門ノート
- `sanitizer-fuzzer-book`
  セキュリティ・キャンプ `Y1: Code Sanitizer・Fuzzer自作ゼミ` に着想を得て、学習用コンパイラの改造から `AddressSanitizer`、`SanitizerCoverage`、coverage-guided fuzzing を追うノート
- `go-runtime-primer`
  Go ランタイムの source を読むために必要な前提知識を、`Scheduler` と `Stack` を主線に整理したノート
- `elf-linker-loader-primer`
  ELF、`SysV ABI`、静的/動的リンク、`_start` から `main` までの起動経路を、Linux x86-64 の最小例でつなぐノート
- `allocator-gc-primer`
  最小 allocator と最小 `mark-sweep` を軸に、OS・sanitizer・Go runtime のメモリ管理をつなぐノート
- `syscalls-process-primer`
  x86-64 の user/kernel 境界を軸に、syscall、process、`fork/exec/wait`、context switch をつなぐノート
- `network-io-primer`
  `socket`、blocking / nonblocking I/O、`select/poll/epoll`、socket buffer、Go `netpoll` を、Linux x86-64 の user/kernel 境界としてつなぐノート
- `service-communication-primer`
  `RPC` と Kafka を題材に、timeout、retry、ordering、delivery semantics、backpressure を軸にサービス間通信の設計判断を整理するノート

## About

このリポジトリの教材は、公開されている学習用記事や OSS を参照しながら、Agent と対話しつつ構成・増補・Typst 化しています。元記事の逐語訳や公式版ではなく、学習しやすい流れになるように再編集した教材です。

要するに、著者が方針を決め、Agent が章立て、増補、Typst 化、体裁調整を一緒に進めているワークスペースです。

## Build

コンテナ経由で PDF を生成します。`Makefile` は `podman` があれば優先し、無ければ `docker` を使います。

```sh
make book
make rust-os-book
make sanitizer-fuzzer-book
make go-runtime-primer
make elf-linker-loader-primer
make allocator-gc-primer
make syscalls-process-primer
make network-io-primer
```

監視モード:

```sh
make watch-book
make watch-rust-os-book
make watch-sanitizer-fuzzer-book
make watch-go-runtime-primer
make watch-elf-linker-loader-primer
make watch-allocator-gc-primer
make watch-syscalls-process-primer
make watch-network-io-primer
make watch-service-communication-primer
```

生成物:

- `compilerbook/main.pdf`
- `rust-os-book/main.pdf`
- `sanitizer-fuzzer-book/main.pdf`
- `go-runtime-primer/main.pdf`
- `elf-linker-loader-primer/main.pdf`
- `allocator-gc-primer/main.pdf`
- `syscalls-process-primer/main.pdf`
- `network-io-primer/main.pdf`
- `service-communication-primer/main.pdf`

## Notes

- 章ファイルや `theme.typ` は部分ファイルなので、通常は各ディレクトリの `main.typ` を入口にビルドします。
- 内容は公開資料を踏まえて再構成した教材であり、原著者の公式配布物ではありません。
- Agent を使っているため下書きや増補の速度は速いですが、最終的な内容確認と構成判断は手元で行う前提です。
