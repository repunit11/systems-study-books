#import "../theme.typ": checkpoint, caution, editorial_note, diagram

= 障害対応と設計 playbook

ここまでで、同期 `RPC` と `Kafka` をどう設計するかを見てきました。しかし本番では、設計は常に障害の形で試されます。payment timeout が続く、analytics lag が急増する、schema 変更で consumer が落ちる、rebalancing が頻発する、トレースは green なのに user は確認メールが届かないと報告する。こうしたときに必要なのは、個別技術の知識より「何をどの順で疑うか」の playbook です。この章では、注文システムを例に、障害対応と日常的な設計レビューの観点を整理します。

#checkpoint[
  この章では次を押さえます。

  - partial failure と cascading failure をどう切り分けるか
  - `RPC` と `Kafka` の使い分けを判断表に落とす方法
  - 典型的なインシデントにどう対処するか
  - observability、ownership、schema governance をどう設計するか
  - architecture review の観点をどう揃えるか
]

== partial failure を通常系として扱う

分散システムでは、全部が一斉に壊れるより、一部だけが遅い・落ちるほうが普通です。`Payment Service` の一部 instance だけが 5xx を返す、`analytics-group` の特定 partition だけ lag が増える、ある consumer だけが新 schema を読めない、といった壊れ方です。

ここで重要なのは、`1つでも成功しているから大丈夫` と見ないことです。user-facing には、一部だけ壊れていても十分に障害です。逆に、部分障害だからこそ degrade で耐えられることもあります。`Search Indexer` が 10 分遅れても注文受付は止めない、といった判断です。

=== cascading failure を防ぐ原則

同期 path の障害が広がる典型パターンは次の通りです。

1. downstream が遅くなる
2. caller の queue と in-flight request が増える
3. timeout と retry が増える
4. 負荷がさらに上がる
5. upstream も巻き添えになる

これを止める原則はすでに出てきました。

- timeout budget を持つ
- retry budget を制限する
- rate / concurrency limit を置く
- circuit breaker で早めに諦める
- critical path を短く保つ

playbook として大切なのは、「障害時ほど仕事を減らす」ことです。全部守ろうとすると全部落ちます。

== インシデント 1: payment timeout が急増した

checkout API の p99 latency が急増し、`Payment Service` の timeout が多発しているとします。このとき確認すべき順番は次です。

1. `Payment Service` の成功率、tail latency、queue saturation を見る
2. `Order Service` 側の retry 数と client-side queue を見る
3. 直近 deploy や config 変更の有無を確認する
4. circuit breaker が開いているか、degraded response があるかを見る
5. idempotency key により重複オーソリが増えていないか確認する

ここでのポイントは、「timeout が起きている = 支払い未実行」と決めつけないことです。response loss や遅延成功の可能性があるので、二重課金を避ける観点を必ず持ちます。

=== インシデント 2: analytics lag だけが増えている

注文受付は正常だが、dashboard 反映が 30 分遅れている状況を考えます。このときは `Kafka` 周辺に視点を移します。

1. `analytics-group` の lag を partition ごとに見る
2. 特定 partition だけ高いなら hot key や poison message を疑う
3. 全体で高いなら consumer throughput、downstream DB、batch size を疑う
4. rebalance 頻度が高いなら instance 安定性と autoscaling を疑う
5. DLQ や retry queue に偏りがないかを見る

ここで重要なのは、「`Kafka` が遅い」とひとまとめにしないことです。問題は broker ではなく、consumer code、partition key、外部依存にあることが多いからです。

=== インシデント 3: schema 変更で一部 consumer が落ちた

event schema 進化の失敗も典型です。`OrderCreated` に新 field を追加したところ、`Search Indexer` は平気だが `Email Worker` が decode error で落ちた、といった状況です。

こうした事故を防ぐには、schema governance が必要です。

- producer は後方互換性を守る
- consumer は未知 field を無視できるようにする
- 破壊的変更は version を分ける
- schema 変更をレビュー対象にする

ここでも ownership が重要です。topic を誰の API と見なすかが曖昧だと、schema は簡単に壊れます。

=== 最初の 15 分でやること

大きな障害では、最初の 15 分で `調べる順番` が重要です。継続例なら、次の順で見ると混乱しにくいです。

1. user-facing impact を確認する
2. 同期 path か非同期 path かを切り分ける
3. 直近 deploy / config change を確認する
4. retry storm や lag amplification が起きていないかを見る
5. degraded mode を使うか、完全停止するかを決める

この順序を持たずに個別 metric をつまみ食いすると、原因と影響範囲を取り違えやすくなります。

#diagram("assets/incident-decision-flow.svg", [最初の 15〜30 分では、まず user impact を見てから sync path と async path を分けて止血手段を選ぶ], width: 96%)

=== alert を症状と原因で分ける

運用でありがちな失敗は、alert が多すぎるのに役に立たないことです。とくに `CPU 80%`、`error log count`、`lag` のような signal を無差別に鳴らすと、症状と原因が混ざってオンコールが動きにくくなります。

整理しやすいのは、alert を次の 2 層に分けることです。

- 症状 alert
  user-facing impact や business SLO の悪化を検知する
- 原因候補 alert
  payment p99、consumer lag、DLQ 増加、schema decode error を検知する

前者は `起こっている障害` を伝え、後者は `どこを疑うか` を伝えます。この 2 つを分けておくと、深夜のインシデントでも優先順位を付けやすくなります。

== `RPC` と `Kafka` の使い分け表

ここまでの議論を、設計時の判断表に落とすと次のようになります。

- いま結果が必要
  `RPC`
- 複数下流へ事実を配りたい
  `Kafka`
- user-facing latency を短くしたい
  必須だけ `RPC`、副作用は `Kafka`
- 強い request/response 因果が必要
  `RPC`
- replay / backfill を前提にしたい
  `Kafka`
- ordering scope を entity 単位で持ちたい
  `Kafka` + key 設計、または idempotent `RPC`
- 強い一括トランザクションが欲しい
  service 境界を見直す。安易にどちらか一方へ期待しない

この表は万能ではありませんが、少なくとも `Kafka は新しいから良い`、`同期のほうが単純だから良い` といった雑な議論を避けやすくなります。

=== 観測を hop ごとと end-to-end で分ける

observability では、hop ごとの健全性と end-to-end の業務体験を分けて見る必要があります。

- hop ごと
  `RPC` error rate、p99 latency、consumer lag、DLQ count
- end-to-end
  注文受付からメール送信完了までの時間
  注文受付から検索反映までの時間
  注文受付から analytics 集計反映までの時間

hop ごとが green でも end-to-end が壊れることはあります。たとえば各 consumer が少しずつ遅く、結果として user 通知が 20 分遅れるケースです。だから business-level signal を持つことが重要です。

```text
Incident dashboard order

1. Business impact
   checkout success rate, mail sent within 5m, search freshness

2. Critical path
   payment p99, inventory error rate, DB tx latency

3. Async path
   consumer lag, DLQ, retry topic depth

4. Change surface
   deploys, schema change, config rollout
```

== ownership と境界

分散システムでは、通信方式の選択はチーム境界の選択でもあります。`RPC` はその場の契約を強くし、`Kafka` は時間的疎結合を増やします。その代わり `Kafka` は ownership が曖昧になりやすいです。

最低でも次を決める必要があります。

- topic / API の owner は誰か
- schema 変更をレビューするのは誰か
- lag / DLQ の責任を持つのは誰か
- redrive 手順を持つのは誰か
- 重大インシデント時にどのチームが pager を持つのか

技術的に正しい設計でも ownership が曖昧だと回りません。これは分散システムの難しさの一部です。

=== 反パターン

本書の内容を逆から見ると、避けたい反パターンも見えてきます。

- なんでも同期 `RPC` fan-out
  critical path が長くなり、障害が連鎖しやすい
- なんでも `Kafka` 化
  user-facing state が曖昧になり、product と合わなくなる
- retry を各 hop で独立に増やす
  障害時に amplification が起きる
- topic を作ったら ownership を決めない
  schema と lag の責任が宙に浮く
- DLQ を置いたが redrive 手順がない
  失敗を隠しただけになる
- replay を考えずに event payload を最小化しすぎる
  後から再計算できなくなる

反パターンは、個別技術の失敗というより、設計判断を先送りした結果として起きます。

#editorial_note[
  良い playbook は、障害時に新しい発想を要求しません。平時から「この症状ならまずここを見る」が共有されている状態を目指します。
]

== 設計レビューの観点

新しい service 間通信を設計するとき、最低限次の問いをレビュー観点として持つと事故が減ります。

1. この call / event の owner は誰か
2. response や publish 成功は何を保証するのか
3. timeout / retry / idempotency はどこで定義されるのか
4. ordering scope は何か
5. replay / backfill は必要か
6. DLQ / redrive はどうするか
7. end-to-end でどの指標を監視するか

この 7 問に答えられないまま implementation に入ると、あとでほぼ必ず戻り工事になります。

=== 段階的に改善するには

すでに同期 `RPC` fan-out が肥大化している system を、いきなり event-driven に全面刷新するのは危険です。現実的には段階的に行います。

1. critical path を可視化する
2. user-facing でなくてよい副作用を洗い出す
3. outbox を置き、まずは 1 つの consumer へ流す
4. consumer を idempotent にし、lag/DLQ を観測する
5. 徐々に fan-out を同期から非同期へ移す

この順序を取ると、設計変更の効果と新しい障害面を少しずつ学べます。

=== runbook に残すべきこと

playbook を実運用へ落とすなら、runbook として明文化すべきです。少なくとも次は残しておく価値があります。

- 主要 API と topic の owner
- 主要 SLO と alert threshold
- DLQ / redrive 手順
- replay 実行時の注意点
- degraded mode の条件
- external provider 障害時の暫定運用

分散システムでは、知識が人に閉じると障害時に復旧速度が大きく落ちます。

=== redrive と rollback を混同しない

`Kafka` や outbox を使い始めると、障害対応で `とりあえず巻き戻す` という言葉が出がちです。しかし実際には、rollback と redrive は別物です。

- rollback
  変更した code や config を以前の状態へ戻す
- redrive
  既に保存されている record をもう一度処理させる

schema 破壊で consumer が落ちた場合、まず必要なのは rollback かもしれません。しかし欠損したメール送信や検索更新を埋めるには、そのあとに redrive が必要です。この 2 つを混ぜると、`binary は戻したが欠損は埋まっていない` 状態で安心してしまいます。

したがって playbook には、`止血` と `データ修復` を分けて書くべきです。分散障害は、process を戻すだけでは終わらないことが多いからです。

#diagram("assets/rollback-vs-redrive.svg", [rollback はこれ以上の悪化を止め、redrive は既に欠けた side effect や projection を修復する], width: 92%)

== ケーススタディ: 同期 fan-out から event 化へ

注文作成 API がもともと `Email Service` と `Search Service` を同期 `RPC` していたとします。これを `Kafka` へ移すときの狙いは、単に速くすることではありません。

- checkout latency を短くする
- email / search の障害を注文受付から切り離す
- replay や backfill を可能にする

ただし移行では、新たに lag、DLQ、schema governance が必要になります。つまり「何が楽になり、何が新しく難しくなるか」を理解したうえで進める必要があります。

=== 移行のロールアウト順序

同期 fan-out から event 化へ移すときは、順序が大切です。安全なのは次の順です。

1. まず outbox だけ入れる
2. 既存同期処理は残したまま、consumer で shadow 処理する
3. lag / DLQ / replay を観測できるようにする
4. 問題ないと確認してから同期 call を外す

この順序なら、いきなり user-facing behavior を変えずに、新しい非同期経路の安定性を確認できます。

=== degraded mode の棚卸し

設計レビューで有効なのは、「何が落ちたらどこまで degraded で耐えるか」を一覧にすることです。たとえば継続例では次のように整理できます。

- `Inventory Service` 障害
  注文受付そのものが止まり得る
- `Payment Service` 障害
  注文受付そのものが止まり得る
- `Email Worker` 障害
  注文受付は継続し、通知だけ遅延させる
- `Analytics Consumer` 障害
  注文受付は継続し、集計だけ遅延させる
- `Search Indexer` 障害
  注文受付は継続し、検索反映だけ遅延させる

この一覧があるだけで、どこを同期に残し、どこを非同期へ逃がすべきかがかなり明確になります。

=== architecture review worksheet

最後に、設計レビューでそのまま使える簡単な worksheet を置いておきます。

```text
Communication name:
Caller:
Callee / Topic owner:

1. Success means:
2. Critical path or asynchronous side effect:
3. Timeout / deadline:
4. Retry policy:
5. Idempotency key / Event ID:
6. Ordering scope:
7. Replay / redrive requirement:
8. Owner during incidents:
9. End-to-end metric:
10. Degraded mode:
```

短いですが、この 10 項目に答えられれば大半の設計議論は具体的になります。

== playbook をチームで運用する

playbook は文書として置くだけでは効きません。次の運用があると初めて意味が出ます。

- 新しい API / topic を追加するときに worksheet を埋める
- schema 変更レビューで ownership と replay 影響を確認する
- インシデント後に `playbook に足りなかった判断` を追記する
- オンコール訓練でケーススタディを使う

つまり playbook は静的な文書ではなく、system の学習記録です。

#diagram("assets/playbook-learning-loop.svg", [設計レビュー、運用、障害、postmortem、game day を回して初めて playbook は強くなる], width: 94%)

=== 障害演習の観点

机上の訓練でも、次の 3 題を回すだけでかなり効きます。

- payment timeout が 10 倍に増えた
- analytics lag が 1 時間に達した
- `OrderCreated` schema 変更で consumer が decode error を出した

それぞれについて、最初に見るダッシュボード、degraded mode、owner、rollback 条件を話せるかを見ると、playbook の弱点が出ます。

=== postmortem で残すべきもの

障害が収束したあとに重要なのは、単に時系列を残すことではありません。次に同じ障害が来たときに判断を短くする材料を残すことです。

最低限ほしいのは次です。

- 最初に見えた症状と真因のズレ
- どの alert が早すぎたか、遅すぎたか
- どの dashboard / trace が効いたか
- rollback と redrive のどちらが必要だったか
- playbook に欠けていた判断分岐

良い postmortem は責任追及の文書ではなく、次回の判断コストを下げる文書です。

=== 30 分インシデントタイムライン

オンコールで useful なのは、抽象論より `最初の 30 分に何をするか` が決まっていることです。継続例なら、次の流れにしておくと混乱が減ります。

```text
0-5 min
  user impact 確認
  checkout / mail / search / analytics のどこが壊れたか切り分ける

5-10 min
  直近 deploy と config change を確認
  retry storm, lag amplification, DLQ 増加を見る

10-20 min
  degraded mode / pause / rollback / breaker のどれで止血するか決める
  owner と連絡経路を固める

20-30 min
  redrive や provider status check など修復の入口を決める
  incident note に判断根拠を残す
```

この粒度まで落とすと、playbook が `読み物` ではなく `初動手順` になります。

=== on-call の役割分担を決める

分散障害では、全員が同じダッシュボードを見ているだけだと進みません。最低限、次の役割があると復旧が速くなります。

- incident commander
  優先順位と次の行動を決める
- domain owner
  payment、`Kafka`、search など個別領域を深掘る
- communicator
  product、support、他チームへ状況を共有する

小規模チームでは 1 人が兼任してもよいですが、役割名があるだけで `誰が判断を持つか` が明確になります。分散障害は技術問題であると同時に coordination 問題でもあります。

=== consumer lag 用の runbook 例

consumer lag は頻度が高いので、例として runbook の最小形を置いておきます。

```text
Symptom:
  analytics lag > 15 min

Check:
  1. affected group / partition
  2. offset progress or stuck
  3. rebalance count
  4. downstream DB / warehouse errors
  5. DLQ / retry topic depth

Immediate action:
  - hot partition なら scale out ではなく key / batch / handler を確認
  - provider or DB failure なら retry topic or pause を検討
  - poison なら DLQ 隔離と fix を優先

Recovery:
  - sample redrive
  - replay rate limit
  - freshness metric normalisation
```

runbook は長文である必要はありません。症状、確認順、止血、回復の 4 段だけでも十分効きます。

=== schema rollout 前の確認

schema 事故は rollback と redrive を同時に要求しやすいので、事前確認の価値が高いです。最低限次を確認すると事故率が下がります。

1. 新 field は optional か
2. 既存 consumer が未知 field を無視できるか
3. replay 対象の旧 record でも意味が壊れないか
4. rollback 後に redrive が必要か
5. topic owner と consumer owner が両方レビューしたか

schema 変更は code diff が小さく見えても、運用影響は大きいことがあります。

=== game day で試す題材

playbook を強くするなら、机上レビューだけでなく小さな演習が要ります。継続例なら次の題材が扱いやすいです。

- payment provider を 10 分だけ timeout させる
- analytics-group の 1 partition を poison message で止める
- `OrderCreated` の新 field を旧 consumer に流す
- Search Indexer の replay と live traffic を同時に走らせる

目的は本番に近い pain を安全に再現し、`何を見るか` と `どこで止血するか` を練習することです。

=== playbook の成熟度を測る

最後に、playbook 自体の品質を測る問いを置いておきます。

1. 代表的な 3 障害について、最初の 15 分の行動が文章なしで言えるか
2. rollback と redrive の判断が runbook に分かれているか
3. owner と pager が topic / API ごとに明示されているか
4. postmortem で増えた判断が playbook へ還元されているか
5. 新メンバーでも worksheet を使って設計レビューに参加できるか

この 5 問に `yes` が増えるほど、playbook は文書ではなく運用資産になります。

== 章末まとめ

この章で大切なのは、障害対応を即興にしないことです。`何を先に見るか`、`どこまで degraded で耐えるか`、`誰が owner か` を先に決めておくと、技術の違いに引きずられにくくなります。

設計が良いとは、平時にきれいに見えることではなく、障害時に判断順序が共有されていることです。

=== この章の設計判断の要点

良い設計とは、常に成功する system を作ることではありません。失敗したときに、どこが壊れ、誰が責任を持ち、どこまで degraded で耐えられるかを先に言語化している system を作ることです。

注文システムの継続例でも、payment timeout、analytics lag、schema 破壊は普通に起きます。重要なのは、それぞれに対して `同期 path を守るのか`、`eventual に追いつけばよいのか`、`人手介入が必要なのか` を決めておくことです。

#caution[
  分散システムでは、障害時の即興は高くつきます。設計文書の価値は、平時ではなく障害時に試されます。
]

=== 演習

1. あなたの system にある通信のうち、`なんでも `Kafka` 化` と `なんでも同期 RPC` のどちらに寄りすぎているかを診断してください。
2. 最も現実的なインシデントを 1 つ選び、最初の 15 分で見る指標と判断を playbook として書いてください。
3. ある topic の owner が曖昧なときに、どのような事故が起こりやすいか列挙してください。
4. end-to-end で監視すべき business metric を 3 つ定義してください。
5. あなたの system で degraded mode を持つべき機能を 3 つ挙げ、完全停止との境界を説明してください。
6. 直近のインシデントを 1 つ選び、worksheet の 10 項目で振り返ってください。

=== この章の出口

本編で組み立てた `同期通信と非同期通信の使い分け`、`失敗時の設計`、`ownership と observability` を、最後は手元で使える形へ落とします。付録では復習、用語、設計レビュー用の問い、次に読む資料をまとめます。
