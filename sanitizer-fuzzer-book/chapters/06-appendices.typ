#import "../theme.typ": editorial_note, checkpoint, caution, terminal

= 付録と次の一歩

本編では、学習用コンパイラへ instrumentation を入れ、heap 専用 `AddressSanitizer` と最小 coverage-guided fuzzer を作る流れを見ました。この章では、ここまでの理解を定着させるための補助線として、典型バグ、演習、用語、実用ツールとの対応関係をまとめます。

== 章ごとの復習ポイント

ここまでの話を短く戻すと、各章の中心は次のように整理できます。

- 導入:
  sanitizer は観測装置、fuzzer は探索装置であり、組み合わせると壊れ方と壊れる入力の両方を自動化できる
- instrumentation:
  学習用コンパイラの load/store や分岐点の直前で計測点を差し込む
- 最小 `ASan`:
  shadow memory、redzone、poison/unpoison、quarantine で heap bug を検出する
- runtime:
  compiler pass だけでは成立せず、allocator 差し替えや report が重要になる
- coverage と fuzzer:
  新しい経路を踏む入力だけを残し、corpus を段階的に育てる

この整理を持っていれば、他の sanitizer や他の fuzzer を学ぶときも、どの層が違うのかを比較しやすくなります。

== 典型的なバグ例

教材として試しやすい最小バグを 3 つ挙げます。

=== heap-buffer-overflow

```c
char *p = malloc(8);
p[8] = 'X';
```

右 redzone への 1 バイト書き込みです。最小 `ASan` でも最も分かりやすく検出できます。

=== heap-use-after-free

```c
int *p = malloc(sizeof(int));
free(p);
*p = 42;
```

quarantine を入れておくと再現性が上がりやすいです。`free` 後に poison のまま寝かせる意味がここで見えます。

=== double-free

```c
void *p = malloc(16);
free(p);
free(p);
```

本書の最小実装でも、allocation ヘッダの状態を見れば防げます。use-after-free と違ってメモリアクセス前ではなく、allocator API そのものの不正です。

== fuzz target の作り方

学習用 target としては、次の条件を満たすものが扱いやすいです。

- `const uint8_t *data, size_t size` のような形で入力を受けられる
- 入力 1 件ごとに初期状態へ戻せる
- 入力が少し変わると分岐も少し変わる
- 例外時や sanitizer 検出時に明確な失敗へ落ちる

コンパイラ系教材との接続を重視するなら、字句解析器や式パーサを target にするのがよいです。入力が文字列なので fuzz しやすく、深い分岐もあり、境界条件も多いからです。

== 小さな演習課題

次の順で課題を足すと理解が深まりやすいです。

1. heap-only `ASan` に double-free 検出を追加する
2. report へ allocation ID と free ID を載せる
3. coverage の記録を block 単位から edge 単位へ変える
4. corpus 選択に「最近新しい coverage を出した seed を優先する」を導入する
5. 字句解析器用の token dictionary を足す

この順序は、前ほど runtime の理解を深める課題で、後ろほど fuzzer の探索効率を上げる課題です。

#checkpoint[
  演習に入る前に、少なくとも次が説明できる状態にしたいです。

  - `malloc` と `free` の周辺に runtime が必要な理由
  - shadow memory と redzone の関係
  - coverage が corpus の足切りに使われる理由
  - sanitizer と fuzzer を分けて考える意味
]

== LLVM/Clang 系との対応表

ここまでの縮小実装を、実際の OSS と対応づけると次のようになります。

- 本書の `asan_check_load/store`
  Clang/LLVM の instrumentation pass が差し込むチェックや compiler-rt の runtime に対応する
- 本書の shadow memory
  ASan の shadow mapping の縮小版に相当する
- 本書の `__cov_hit`
  `SanitizerCoverage` の `trace-pc-guard` や類似の callback に相当する
- 本書の最小 fuzzer loop
  libFuzzer の基本ループや AFL 系の corpus 育成の核心に相当する

ここで大切なのは「完全一致」ではなく、「役割が同じ」ことです。実用ツールはこの上に最適化、互換性、並列化、再現性向上の仕組みが積み上がっています。

== 用語小事典

- `instrumentation`
  プログラムへ観測用コードを埋め込むこと
- `shadow memory`
  実メモリに対応するメタ情報を持つ別メモリ領域
- `redzone`
  有効領域の周囲へ置く poison 済みの緩衝帯
- `poison`
  アクセス禁止として印を付けること
- `quarantine`
  解放済みブロックをすぐ再利用せず寝かせる待機領域
- `coverage`
  どのコード経路を通ったかの記録
- `corpus`
  将来の mutation の素材として残しておく入力集合
- `in-process fuzzing`
  同一プロセス内で target を何度も呼ぶ方式
- `interceptor`
  標準関数や allocator を差し替えて監視する仕組み

== よくあるつまずき

== sanitizer を入れたのに何も検出しない

最初に疑うべきは、load/store の差し込み位置と `malloc`/`free` の差し替えです。shadow だけあっても、その更新が allocator 連携で壊れていれば意味がありません。

== coverage が増えない

計測点が少なすぎるか、bitmap の更新が入力ごとにリセットされていない可能性があります。また、target が毎回すぐ同じ構文エラーで終わっていることもあります。

== fuzzing すると再現しない crash が出る

in-process 実行で状態が残っている可能性があります。global state、静的バッファ、乱数 seed、allocator 状態の残り方を疑います。

== ASan と fuzzer を一緒にすると遅すぎる

正常です。両方とも実行時コストを払って観測力を得る道具だからです。学習段階では性能より観測を優先します。

== さらに進むなら

本書の次に進む方向は大きく 3 つあります。

第一は sanitizer 側を深める道です。stack/global instrumentation、`UBSan`、`MSan`、interceptor 設計、stack trace 収集へ進めます。

第二は fuzzer 側を深める道です。dictionary、grammar-aware fuzzing、fork server、coverage 以外の特徴量、分散 fuzzing へ進めます。

第三は解析対象を広げる道です。ファイルフォーマット、ネットワークプロトコル、コンパイラやパーサ、JIT、VM など、target の構造を利用した fuzzing へ進めます。

== 参考にするとよい OSS

- Clang `AddressSanitizer` documentation
  `https://clang.llvm.org/docs/AddressSanitizer.html`
- Clang `SanitizerCoverage` documentation
  `https://clang.llvm.org/docs/SanitizerCoverage.html`
- LLVM `libFuzzer` documentation
  `https://llvm.org/docs/LibFuzzer.html`
- `AFL++`
  `https://github.com/AFLplusplus/AFLplusplus`
- セキュリティ・キャンプ2025 `Y1 Code Sanitizer・Fuzzer自作ゼミ`
  `https://www.ipa.go.jp/jinzai/security-camp/2025/camp/zenkoku/program/y.html`

#editorial_note[
  一次資料を読むと、ここで省略した論点が多数出てきます。特に ASan の stack/global 対応、SanitizerCoverage の mode 違い、libFuzzer の mutation policy、AFL++ の process model は、本書の縮小版よりずっと広いです。縮小版の役割は、それらを読むための地図を渡すことにあります。
]

= おわりに

サニタイザやファザは、使うだけならコンパイラオプションや CLI の話に見えます。しかし一度小さく再実装すると、それらが「コンパイラ」「runtime」「メタデータ」「探索」の 4 層でできていることがはっきり見えます。この見え方は、単にバグを見つけるためだけではなく、ツールの限界や誤検知、性能コストを理解するうえでも非常に重要です。

`compilerbook` が「コードを生成する側」の視点を与えてくれたなら、本書は「生成したコードを観測し、壊し、調べる側」の視点を補います。この二つがつながると、コンパイラオプション一つの裏側にもかなり厚い設計があることが自然に見えてきます。
