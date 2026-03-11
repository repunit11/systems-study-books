#import "../theme.typ": checkpoint, editorial_note, caution, diagram

= 付録: 復習、用語、次の一歩

本編では、`RPC` と `Kafka` を技術名としてではなく、サービス間通信を設計するための判断軸として見てきました。この章では、復習、自己点検用の問い、用語集、設計レビュー観点、次に読む資料をまとめます。新しい topic を増やすというより、本書を読んだあとに手元の system へ戻すための章です。

#checkpoint[
  この章では次を押さえます。

  - 各章の復習ポイント
  - 自己点検用の問い
  - よく使う用語の整理
  - 設計レビューで使える簡易チェックリスト
  - 次に深める方向
]

== 章ごとの復習ポイント

- 導入
  local call の直感は分散通信では壊れる。技術名ではなく、いつ結果が必要か、失敗時に誰が責任を持つかを軸に考える。
- request/response
  critical path、response の意味、timeout budget、idempotency を最初に定義する。
- `RPC` の運用設計
  service discovery、load balancing、queue、retry budget、breaker、tracing は同期通信の一部である。
- `Kafka` と log
  event を command と混ぜず、`topic`、`partition`、`offset`、key 設計で ordering scope を表現する。
- consumer
  lag、rebalancing、DLQ、redrive、idempotency が本体であり、publish 成功だけでは system は完成しない。
- semantics と consistency
  at-least-once / exactly-once は hop 単体でなく end-to-end で読む。outbox と saga は境界整理の道具である。
- playbook
  ownership、schema governance、observability、degraded mode を先に決めることが、障害時の即興を減らす。

== 自己点検用の問い

本書を読み終えたら、手元の system に対して次の問いに答えてみると理解が固まります。

1. いま最も user-facing な API の critical path は何か
2. その API が成功を返した時点で、何を保証しているか
3. timeout と retry はどこで定義されているか
4. idempotency key が必要な call はどれか
5. event の ordering scope は何か
6. lag が増えたとき、誰が見るべきか
7. DLQ に入った record をどう redrive するか
8. end-to-end の business metric は何か

この 8 問に答えられない箇所は、設計がまだ暗黙のまま残っている可能性が高いです。

== 設計レビュー用の簡易チェックリスト

新しい service 間通信を提案するとき、次のチェックリストをそのまま使えます。

- この通信は `RPC` か event か。なぜその形なのか。
- caller はいつ結果を必要としているのか。
- response / append 成功は何を保証するのか。
- timeout / deadline / retry policy はどこにあるか。
- idempotency key や `event_id` は何か。
- ordering scope は何か。
- consumer lag や DLQ の owner は誰か。
- replay / backfill が必要になったときに対応できるか。
- schema 変更の互換性ルールは何か。
- 障害時の degraded mode はあるか。

短い checklist ですが、多くの設計事故はここで検知できます。

== クイック比較表

本書の後半では比較表が何度も出てきます。読み返しやすさのために、もっとも重要な比較をここへまとめておきます。

```text
RPC vs Kafka

RPC
  向いている: いま結果が必要な仕事
  主な難しさ: timeout, retry, queue, cascading failure
  成功の意味: response の定義で決まる

Kafka
  向いている: response 後へ押し出したい事実の配布
  主な難しさ: ordering, lag, replay, consumer ownership
  成功の意味: append, consumer processing, user-visible effect を分けて考える
```

```text
Sync path vs Async path

Sync path
  主眼: accepted / rejected / temporary_failure (= unknown to caller) を早く狭める
  代表要素: timeout budget, idempotency key, failure mapping

Async path
  主眼: side effect を疎結合に進める
  代表要素: event schema, consumer lag, DLQ, redrive
```

```text
Retry family

retry
  同じ call / record を再試行する

replay
  過去 log を読み直す

redrive
  隔離済み record を修復後に再投入する

rollback
  code / config を以前の版へ戻す
```

この 3 表だけでも、`いま議論しているのはどの層の問題か` をかなり切り分けやすくなります。

== 本書での表記ルール

本文では似た名前が複数出るので、ここで表記を固定します。

- `SubmitOrder`
  user からの同期 request 名
- `OrderAccepted`
  同期 path が成立したときの意味
- `OrderCreated`
  domain event の概念名
- `order-created`
  topic 名や log 上の event type 名
- `idempotency key`
  概念としての一般名
- `IdempotencyKey`
  コード中の field 名
- `event_id`
  storage や payload の一般的な field 名
- `EventID`
  コード中の field 名

このルールは厳密な文法というより、`概念名`、`log 上の名前`、`コード識別子` を混ぜないための目印です。分散システムでは、名前のズレがそのまま責務のズレになりやすいので、初学段階ほど明示したほうが読みやすくなります。

== 用語小事典

- critical path
  user-facing な request が成功と見なされるまでに必要な処理列
- timeout
  一定時間待って結果が来なければ諦める規則
- deadline
  request 全体が完了すべき絶対期限
- retry budget
  障害時に追加試行をどこまで許すかの上限
- idempotency
  同じ操作を何度繰り返しても、1 回実行した場合と最終状態が同じになる性質
- service discovery
  論理名から動的な instance 集合を見つける仕組み
- load balancing
  request を複数 instance に分配する仕組み
- circuit breaker
  失敗率が高い依存先への呼び出しを一時的に止める仕組み
- event
  すでに起きた事実を記録するもの
- command
  特定の相手にやってほしい仕事を依頼するもの
- topic
  同種の record を置く `Kafka` の論理名
- partition
  並列性と順序保証の単位
- offset
  partition 内の位置を表す連番
- consumer group
  同じ論理 consumer を複数 instance で分担する仕組み
- lag
  consumer がまだ追いついていない量
- rebalance
  consumer group 内で partition 所有者を再配分すること
- poison message
  繰り返し処理しても失敗する record
- DLQ
  一定回数の再試行後も処理できなかった record を隔離する場所
- redrive
  DLQ や保留領域から record を再投入すること
- outbox
  state 変更と publish 要求を同じ transaction で記録する pattern
- saga
  複数 service のローカル処理と補償で全体整合を取る発想
- replay
  過去 record を再読して処理をやり直すこと
- backfill
  過去欠損分をあとから埋める処理
- ordering scope
  順序を守りたい単位
- end-to-end consistency
  複数 hop をまたいだ業務操作全体の整合性

== consumer タイプの比較

継続例で使った 3 つの consumer を、実務判断向けに簡単に並べ直しておきます。

```text
Email Worker
  許容 lag: 小さめ
  replay safety: 低い
  重要事項: duplicate suppression, provider quota, notification UX

Analytics Consumer
  許容 lag: 中〜大
  replay safety: 高い
  重要事項: event time, throughput, backfill, warehouse load

Search Indexer
  許容 lag: 中
  replay safety: 比較的高い
  重要事項: upsert, rebuild, live traffic と replay の分離
```

この比較を頭に置くと、`同じ topic を読んでいるから同じ運用でよい` という誤解を避けやすくなります。

== よくある誤解

=== `RPC` は関数呼び出しの延長にすぎない

違います。queue、connection pool、timeout、retry、partial failure を含む別物です。

=== `Kafka` は queue の高機能版である

一面ではそう使えますが、本質は複数 consumer が独立進捗で読む append-only log です。

=== exactly-once を使えば重複はもう考えなくてよい

成立範囲を限定しなければ危険です。外部 side effect は依然として application 設計が必要です。

=== DLQ に送れば安全である

安全ではありません。隔離しただけです。redrive 手順、owner、再実行時 idempotency が必要です。

=== lag は worker を増やせば解決する

hot partition、外部依存、poison message、rebalancing が原因なら、単純なスケールアウトでは解けません。

#caution[
  分散システムで危険なのは、間違った答えそのものより、暗黙の前提に気付かないことです。よくある誤解を定期的に見直すだけでも事故は減ります。
]

== ミニケーススタディ

=== ケース 1: 注文確認メールが二重送信された

考えるべき問い:

- どこで retry が起きたか
- メール送信 API に idempotency key はあるか
- 送信履歴は `event_id` と結びついているか
- commit と side effect の順序はどうなっているか

=== ケース 2: 検索結果への反映が遅い

考えるべき問い:

- lag は全 partition で高いか、一部だけか
- index update は upsert か append か
- bulk 処理と refresh interval は妥当か
- event payload だけで処理できるか、それとも追加 `RPC` があるか

=== ケース 3: 注文受付は成功するが analytics が欠損する

考えるべき問い:

- outbox は書けているか
- relay は動いているか
- consumer は commit を先行していないか
- 欠損検知の metric はあるか

こうしたケースは、本書の各章を実務へ戻す入口として使えます。

== 設計レビュー演習

以下の 3 題は、チームで設計レビューするときの題材として使えます。

1. `OrderCreated` event から email と search を非同期化するとき、何を同期 path に残すか。
2. payment timeout 時に二重課金を避けながら user へ何を返すか。
3. analytics lag が 1 時間まで伸びても注文受付を止めないなら、どの指標を alert にするか。

短い題材ですが、本書の中心線である `critical path`、`idempotency`、`lag`、`ownership` を一度に話せます。

== 30 分レビューの進め方

設計レビューは、資料を読むだけだと抽象論で終わりがちです。30 分だけ使うなら、次の順が効率的です。

1. 最初の 5 分で `成功とは何か` を定義する
2. 次の 10 分で critical path と非同期 side effect を分ける
3. 次の 10 分で timeout / retry / idempotency / ordering scope を詰める
4. 最後の 5 分で owner、alert、redrive を確認する

この順なら、transport の好みより `どこに失敗を押し出すか` の議論へ自然に入れます。

#diagram("assets/review-flow-30min.svg", [30 分レビューでは、成功の意味から始めて、critical path、failure contract、ownership へ順に落とす], width: 95%)

== 20 の確認質問

最後に、実務へ戻るときの短い確認質問を並べます。答えられない項目は、そのまま設計の曖昧さです。

1. この API の成功は何を意味するか。
2. timeout は誰が決めるか。
3. retry は誰が行うか。
4. 自動 retry してはいけない call はどれか。
5. idempotency key はどこで生成するか。
6. `event_id` は stable か。
7. ordering scope は何か。
8. replay したくなる consumer はどれか。
9. replay してはいけない consumer はどれか。
10. DLQ の owner は誰か。
11. redrive 手順はどこに書いてあるか。
12. lag の alert threshold は何に基づくか。
13. business error と technical error は分かれているか。
14. schema 変更のレビュー担当は誰か。
15. end-to-end metric は何か。
16. degraded mode は product と共有されているか。
17. topic の名前は事実を表しているか。
18. command と event を混ぜていないか。
19. critical path に本当に必要な依存先だけが入っているか。
20. 障害時に最初の 15 分で見るダッシュボードは決まっているか。

== 手元の system でやる小さなワーク

本書を閉じたあと、1 時間だけ使えるなら次の 4 つをやると効果があります。

1. もっとも重要な API を 1 本選び、critical path を箱書きする
2. その API の成功が何を保証するかを 3 行で書く
3. 関連する event を 1 つ選び、owner、ordering scope、redrive 手順を書き出す
4. `いま playbook が無い` と思うインシデントを 1 つ選び、最初の 15 分の行動を書いてみる

理解は読むだけでは定着しません。自分の system に引きつけて `曖昧な前提` を見つけたところから価値が出ます。

== ミニケーススタディを増やす

短いケースをもう 3 つ追加します。どれも正解を暗記するためではなく、判断軸を使う練習のためのものです。

=== ケース 4: DLQ が増えているが user 影響はまだ見えない

考えるべき問い:

- どの consumer group の DLQ か
- 将来的に user-facing へ波及する経路はあるか
- redrive 前に code fix が必要か
- DLQ に隔離した record の寿命はどうなっているか

=== ケース 5: payment provider が断続的に 502 を返す

考えるべき問い:

- technical error と business reject は分かれているか
- idempotency key により再試行安全性を担保できるか
- caller と provider の timeout のどちらが先に切れているか
- degraded mode と user 向け表示をどうするか

=== ケース 6: replay 中だけ analytics warehouse が飽和する

考えるべき問い:

- replay rate を通常 traffic と別に制御できるか
- backfill を夜間に寄せるべきか
- replay 済み record をどう追跡するか
- event payload だけで処理できるか、追加読みが詰まりを作っていないか

== 設計の危険信号

設計レビューで `この会話が出たら一段立ち止まる` という危険信号もあります。継続例に限らず、次はかなり強い warning です。

- `とりあえず全部 retry しておく`
- `DLQ に送るので大丈夫`
- `event は ID だけにして、足りない分は後で RPC する`
- `owner は特に決めなくても使う人が見る`
- `exactly-once があるので重複は考えなくてよい`
- `lag は台数を増やせばそのうち解決する`

こうした言い方が出たら、たいてい failure contract か ownership がまだ曖昧です。

== 設計メモの最小テンプレート

新しい API や topic を提案するとき、長い設計書がなくても次の形だけでかなり議論できます。

```text
Title:
Owner:

User-visible success:
Critical path:
Async side effects:
Failure modes:
Retry / idempotency:
Ordering scope:
Replay / redrive:
Primary metrics:
```

これを 1 ページで書けない場合、実装前にまだ決めるべきことが残っている可能性が高いです。

== runbook の最小テンプレート

runbook も同じで、最初から大きくしすぎるより最小形を持つほうが効きます。

```text
Symptom:
Impact:
Owner:

Check order:
1.
2.
3.

Immediate mitigation:
Recovery:
Rollback needed? yes / no
Redrive needed? yes / no
```

この型を topic / API ごとに埋めていくと、障害時の即興がかなり減ります。

#diagram("assets/worksheet-runbook-pair.svg", [worksheet は設計時の意味を固定し、runbook は障害時の確認順と回復手順を固定する], width: 94%)

== 90 分ワークショップ案

チームで本書の内容を実務へ結び付けるなら、90 分の短いワークショップがやりやすいです。

1. 20 分
   もっとも重要な user-facing API の critical path を書く
2. 20 分
   主要 event の owner、ordering scope、replay 需要を書く
3. 20 分
   payment timeout か consumer lag のどちらかを題材に初動を話す
4. 20 分
   worksheet と runbook を 1 つずつ埋める
5. 10 分
   playbook に無い判断を洗い出す

この進め方だと、抽象論で終わらず、実際の system に戻りやすいです。

== 学習を深める順序

本書のあとに何を読むかは、伸ばしたい方向で変わります。

- `RPC` を深める
  service discovery、service mesh、hedged requests、adaptive concurrency
- `Kafka` を深める
  replication、ISR、transactions、compaction、KRaft
- consistency を深める
  event sourcing、CQRS、workflow engine、transactional messaging
- observability を深める
  distributed tracing、SLO、error budget、log correlation
- 組織運用を深める
  schema registry、API review、incident response、runbook 整備

最初から全方向へ行く必要はありません。実務で一番痛い箇所から掘るのがよいです。

== 章別の読み返し順

手元で特定の問題にぶつかったときは、最初から読み返す必要はありません。次の順が効率的です。

- timeout / retry / 二重実行の問題
  `02` -> `03` -> `06`
- lag / DLQ / consumer 停滞の問題
  `05` -> `07` -> `08`
- ordering / replay / outbox の問題
  `04` -> `06` -> `07`
- 設計レビューや新規機能追加
  `01` -> `07` -> `08`

== 参考資料

- `Designing Data-Intensive Applications`
- `Building Microservices`
- `Kafka` の公式 document
- `gRPC` の公式 document
- `Google SRE Book`
- OpenTelemetry の公式 document
- transactional outbox pattern や saga pattern の各種解説

#editorial_note[
  技術書を読んだあとに本当に価値が出るのは、手元の system に問いを持ち帰れたときです。付録はそのためにあります。
]

== 手元で使う 1 ページ worksheet

最後に、紙 1 枚で済む最小 worksheet を置いておきます。新しい API や topic を追加するとき、この 8 項目だけでも書いておくと会話がかなり具体化します。

```text
Communication:
Owner:
User-facing? yes / no

Success means:
Critical path budget:
Retry + idempotency rule:
Ordering scope:
Replay / redrive plan:
Primary alert:
```

短すぎるように見えますが、短いからこそ毎回書けます。分散設計では、立派な文書より毎回更新される小さな文書のほうが効くことが多いです。

== 4 週間の使い方

この本を読み終えたあと、4 週間だけでも次の使い方をすると定着しやすいです。

1. 第 1 週
   critical path と response meaning を手元の API で 1 本書く
2. 第 2 週
   主要 topic / consumer の owner、lag、redrive を棚卸しする
3. 第 3 週
   もっとも怖いインシデント 1 件の runbook を作る
4. 第 4 週
   設計レビューか game day で worksheet を実際に使う

知識を `知っている` から `使える` に変えるには、短い反復が一番効きます。

#diagram("assets/four-week-roadmap.svg", [読み終えたあとに 4 週間だけでも回すと、critical path、owner、runbook、review の習慣が残りやすい], width: 95%)

= おわりに

サービス間通信を理解するために必要なのは、個別 product の feature list を覚えることではありません。同期 request と非同期 event が、それぞれ何を保証し、どこへ難しさを押し出し、失敗時に誰へ責任を残すのかを言葉にできることです。

一度この地図を持つと、新しい broker や `RPC` framework を見ても、「いま解こうとしているのは timeout の問題か、ordering の問題か、consumer ownership の問題か」と整理しやすくなります。そこまで来れば、技術名は流行りのラベルではなく、目的に応じた道具として選びやすくなります。
