#import "../theme.typ": checkpoint, caution, terminal

= `SanitizerCoverage` と最小 fuzzer

sanitizer が「壊れた瞬間を観測する装置」なら、fuzzer は「壊れる入力を探す装置」です。この章では、coverage instrumentation を加えた最小 runtime を作り、その情報を使って corpus を育てる in-process fuzzer を組み立てます。主役は `SanitizerCoverage` に相当する edge coverage で、これを面白さの指標に使います。

#checkpoint[
  この章の目標は次の通りです。

  - coverage-guided fuzzing の「guided」が何を意味するか説明できる
  - edge coverage を bitmap に落とす発想を説明できる
  - sanitizer と fuzzer を統合すると silent corruption を効率よく見つけやすくなることを説明できる
]

== なぜ coverage が必要か

乱数で適当に入力を投げるだけでも、たまにはクラッシュを引けます。しかし大半の時間は、すでに見た経路を何度も踏み直すことになります。そこで「この入力は前と違う実行経路を踏んだか」を測り、そのような入力だけを残すと探索効率が大きく上がります。これが coverage-guided fuzzing の核です。

重要なのは、coverage が正しさの指標ではないことです。coverage は *新しさの近似* です。新しい edge を踏んだ入力は、まだ見ていない深い条件分岐やバグへ近づいているかもしれない。だから残す。これだけです。

== edge coverage の最小実装

教材として一番分かりやすいのは edge coverage です。各 basic block や分岐辺に ID を振り、実行時にその ID を bitmap へ反映します。本家 `SanitizerCoverage` の `trace-pc-guard` は、各計測点に guard 変数を置き、その値を callback へ渡す形で実装されます。学習用ではもっと単純に、コンパイラが連番 ID を埋め込んでも構いません。

たとえば次のような疑似呼び出しを各分岐周辺へ差し込みます。

```c
__cov_hit(37);
```

runtime 側では `bitmap[37] = 1` でも最初は十分です。もう少し本家に寄せるなら、直前の edge ID と xor を取る AFL 風の表現もできますが、最初の教材では単純な集合でもよいです。

== 計測点をどこへ置くか

coverage は load/store とは違い、全てのメモリアクセスへ入れる必要はありません。むしろ制御フローの変化点に置くのが自然です。最小実装なら次を基準にすると分かりやすいです。

- `if` の then 入口
- `else` の入口
- `while` / `for` の本体入口
- 関数入口
- `switch` の各 case 入口

これだけでも、入力によってどの枝へ進んだかがかなり見えます。プログラム全体の全 edge を正確に取るより、「新しい分岐が踏まれたか」を取れれば学習上は十分です。

== runtime の bitmap

coverage runtime は、入力 1 件ごとに bitmap をリセットし、実行中に hit を記録し、終了後に「今まで見ていないビットが立ったか」を調べます。新しいビットがあればその入力を corpus へ残し、なければ捨てます。

この流れは非常に単純ですが、fuzzer の核心です。入力生成アルゴリズムより先に、「何を残すか」の判定基準が必要なのです。探索は評価関数なしには成立しません。

== 最小 fuzzer の外形

in-process の最小 fuzzer は、概念的には次のループです。

1. corpus から 1 件選ぶ
2. 少し mutation する
3. coverage bitmap を初期化する
4. target function へ入力する
5. 新しい coverage なら保存する
6. sanitizer 失敗や crash なら保存して終了または継続する

```text
while true:
  seed = choose(corpus)
  input = mutate(seed)
  reset_bitmap()
  run_target(input)
  if crashes: save_crash(input)
  if expands_coverage: corpus.add(input)
```

このループが分かれば、libFuzzer も AFL++ もかなり見通しが良くなります。違いは主に mutation、スケジューリング、process model、signal の扱い、coverage の取り方、周辺最適化です。

== fuzz target とは何か

fuzzer は何でも勝手に実行してくれるわけではありません。対象となる関数、すなわち fuzz target が必要です。一般には「バイト列を受け取り、それをパース・解釈・実行する関数」を用意します。

教材としては、学習用コンパイラ自身をターゲットにするのが一番自然です。たとえば「入力文字列を C の一部としてパースし、構文木を作り、コード生成し、必要なら実行する」ような関数を対象にできます。これにより、本そのものが前の本とつながります。

== mutation の最初の形

最初の mutation は素朴で構いません。

- 1 バイト反転
- 1 バイト挿入
- 1 バイト削除
- 既存断片の複製

これだけでも、条件分岐が浅いプログラムにはかなり効きます。重要なのは mutation の賢さよりも、coverage に基づいて *残す入力を選べる* ことです。guided でない random test との違いはここにあります。

== corpus が育つとは何か

corpus は単なる保存フォルダではありません。探索の足場です。新しい coverage を生んだ入力だけを残すことで、「すでに有効だった変異の結果」を次の変異の素材として再利用します。これが探索の階段になります。

単なる乱数列からいきなり深い条件へ入るのは難しくても、少しずつ条件を突破する入力が残っていけば、次第に深い地点へ届きます。fuzzer の賢さは、未来の入力を直接予測することより、過去に有効だった入力をうまく温存することにあります。

== sanitizer との統合

sanitizer を入れた target を fuzz すると、クラッシュの意味が豊かになります。単に segmentation fault したかどうかではなく、heap overflow や use-after-free が「検出された」時点で失敗として扱えます。つまり silent memory corruption をより早い失敗へ変換できます。

この統合はとても重要です。もし sanitizer がなければ、壊れた入力がたまたま即時クラッシュしない限り見逃すかもしれません。sanitizer があれば、危険なアクセスの瞬間に止められます。ファザはその失敗入力を保存し、再現入力として残します。

== 再現性と最小化

クラッシュ入力が見つかったら、次に欲しいのは再現性と最小化です。学習用最小版なら、まず「クラッシュ入力をそのまま保存する」で十分です。ただし教材としては、「なぜ最小化が欲しいのか」も触れておきたいです。

長い入力より短い入力のほうが、人間が原因を追いやすいからです。libFuzzer や AFL++ の周辺には input minimization の仕組みがありますが、本書では概念紹介に留め、「不要なバイトを削っても同じ crash が起きるなら残す」という発想だけを説明します。

== dictionary と grammar の話

coverage-guided fuzzing はバイト列 mutation だけでも強いですが、入力形式が構造化されるほど限界が見えます。たとえば C ソース片や JSON のような文法を持つ入力では、単純 mutation だけではすぐ構文エラーへ落ちがちです。そこで dictionary や grammar-aware fuzzing の考え方が出てきます。

本書ではそこまで実装しません。ただし付録で、「トークン辞書を持つだけでも分岐の深い場所へ入りやすくなる」ことは触れます。学習用コンパイラを fuzz target にする場合、この話は特に自然です。

== process model の違い

本書の最小 fuzzer は in-process です。これは高速で実装も簡単ですが、target が状態を汚しやすいという問題があります。プロセスを毎回分ける fork-server 型や外部プロセス実行型には、隔離の利点があります。

ここで本家との差分を整理しておくとよいです。

- `libFuzzer`
  in-process を前提にし、高速な反復を重視する
- `AFL++`
  fork-server や binary instrumentation を含む広い実践系
- `Centipede`
  coverage 以外の特徴量も扱う現代的な探索器

学習用としては in-process で十分ですが、この違いを知っておくと現実のツール選択が分かりやすくなります。

== 最小実装でも見える改善点

単純な fuzzer を作っただけでも、次の改善案が自然に浮かびます。

- どの seed を優先して変異するか
- どの mutation が新しい coverage を出しやすいか
- タイムアウトや OOM をどう扱うか
- crash の重複判定をどうするか
- dictionary をどう導入するか

この「改善点が自分で見える」ことが、再実装型教材の価値です。既製ツールを使うだけだと、設定項目が多いだけに見えますが、自前版を持つとその理由が腑に落ちます。

#caution[
  sanitizer を有効にした in-process fuzzing では、target の状態汚染や global state の残り方に注意が必要です。入力 1 件ごとに初期状態へ戻せない target は、coverage や crash の再現性を損ないやすくなります。
]

== この章の出口

これで、本書の主線である `ASan → coverage → fuzzer` が一通りつながりました。最後の章では、ここまでを踏まえた実践上の見方、比較対象の OSS、典型バグ、演習、参考資料をまとめます。
