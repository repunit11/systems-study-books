#import "../theme.typ": checkpoint, caution, editorial_note

= `RPC` の運用設計

前章では request/response を critical path の設計として見ました。しかし本番 system で同期通信を扱うには、それだけでは足りません。client はどの instance へつなぐのか、timeout は hop ごとにどう配るのか、retry はどこまで許すのか、connection pool はどのくらい持つのか、streaming をいつ使うのか、といった運用の論点が必ず出てきます。この章では、注文システムの `Inventory Service` と `Payment Service` を題材に、`RPC` を運用可能にするための設計を整理します。

#checkpoint[
  この章では次を押さえます。

  - service discovery と load balancing の役割
  - connection pool と queueing が latency をどう変えるか
  - retry budget、circuit breaker、rate limit の意味
  - unary と streaming をどう使い分けるか
  - tracing / metrics で critical path をどう観測するか
]

== 論理名で呼ぶということ

`Order Service` は実際には `inventory-service-7f4d9b` のような pod 名を知りません。知っているのは `inventory-service` という論理名だけです。そこから先は service discovery と load balancing の仕事です。

この一見地味な仕組みが重要なのは、分散システムでは「相手」は固定 1 台ではないからです。deploy によって instance は増減し、rolling restart が走り、一部 instance だけが unhealthy になることもあります。`RPC` client は単なる library call ではなく、動的に変わる接続先集合へ request を流す component です。

設計上は、次の問いを持つと理解しやすくなります。

- 接続先一覧は誰が更新するのか
- unhealthy instance を誰が外すのか
- retry 時に同じ instance へ行くのか、別 instance へ送るのか
- region / zone / cell をまたぐとき、どこまで local preference を持たせるのか

=== load balancing は throughput だけの話ではない

load balancing と聞くと、多くの人は「負荷を均等にすること」と理解します。もちろんそれも大切ですが、実務ではそれ以上の役割があります。

- skew を減らし、一部 instance だけが詰まるのを避ける
- rolling deploy 中に traffic を滑らかに移す
- 障害 instance を切り離す
- zone 障害時に traffic を逃がす

つまり load balancing は性能最適化というより、failure containment の仕組みでもあります。

ただし load balancing は万能ではありません。retry と組み合わさると、もともと 1 回で済んだ request が複数 instance に飛び、重複実行の面積が広がることもあります。特に stateful な side effect を持つ `Payment Service` では、この点を軽視できません。

=== どの balancing policy を選ぶか

単純な round-robin は分かりやすいですが、queue が長い instance へも均等に投げてしまうことがあります。一方 least-loaded 系は理論上よさそうでも、観測の遅れや load estimate の難しさがあります。

実務で大切なのは、policy 名の暗記より、`局所的に速い instance を優先しすぎて偏らないか`、`失敗 instance をどれくらい早く避けられるか` を考えることです。最初の一冊としては、次の程度の理解で十分です。

- round-robin
  単純だが、queue length を見ない
- random / power of two choices
  実装が比較的簡単で偏りを減らしやすい
- request-aware policy
  latency や in-flight 数を見て選ぶが、複雑になりやすい

system の初期段階では単純な policy でも構いません。重要なのは policy を固定することではなく、tail latency と error rate を見て変えられることです。

=== connection pool は invisible queue でもある

`RPC` client library は多くの場合、下に connection pool を持ちます。これは便利ですが、同時に invisible queue にもなります。pool size が小さすぎると request は socket 待ちで詰まり、大きすぎると server 側の queue や kernel resource を圧迫します。

つまり caller の latency は、callee の実処理だけでなく、次の 3 つの待ち時間の合計です。

- caller 側 queue / pool 待ち
- network 往復
- callee 側 queue / 実行待ち

多くのトラブルは、真ん中の network ではなく、両端の queue にあります。`Inventory Service` が遅いように見えて、実際には caller 側で connection 待ちが起きていた、というのはよくある話です。

```text
caller goroutine
  -> client-side queue
    -> connection pool acquire
      -> network
        -> server listener queue
          -> server worker queue
            -> handler
```

この図を見ると分かるように、`RPC latency` は 1 つの箱の時間ではありません。複数 queue の足し算です。

== timeout budget と retry budget

前章で timeout budget を見ましたが、運用では retry budget も同じくらい重要です。retry budget とは、「失敗時にどのくらいまで追加試行を許すか」という上限です。これがないと、障害時に request が雪だるま式に増えます。

注文システムなら、たとえば次のような設計が考えられます。

- `Inventory Service`
  小さな timeout、1 回まで retry、同一 request 内で total 250ms を超えない
- `Payment Service`
  自動 retry はかなり保守的、idempotency key 前提、gateway 側 failure taxonomy を強く見る

重要なのは、全 hop が独立に 3 回 retry するような構成を避けることです。API Gateway、Order Service、client library、sidecar が全部 retry すると、障害時の amplification は簡単に数倍から数十倍になります。

```text
Checkout path timeout sketch

Client -> API Gateway                 total budget 1500ms
API Gateway -> Order Service         1400ms
Order Service -> Inventory Service    250ms
Order Service -> Payment Service      400ms
Order Service -> DB transaction       250ms
Leftover for retry / jitter / write   300ms
```

このように budget を明示しておくと、「どこが勝手に待ちすぎているか」を議論しやすくなります。分散システムの timeout は気分で決める数字ではなく、全体制約の配分です。

=== circuit breaker は何を守るのか

circuit breaker は fashionable な pattern ですが、本質は単純です。すでに失敗率が高く、短期的に回復しそうにない依存先に対して、これ以上 caller 資源を浪費しないようにする仕組みです。

breaker を入れる場所で大切なのは、「誰を守りたいのか」を明確にすることです。

- caller を守る
  goroutine、thread、connection、memory の枯渇を防ぐ
- callee を守る
  既に苦しい依存先へ無駄な retry を積まない
- user を守る
  無限に spinning せず、早めに degraded response を返す

breaker が開いたときに何を返すかも設計が要ります。たとえば recommendation service なら degraded でもよいかもしれませんが、payment authorization では単に `success` に倒すわけにはいきません。

=== rate limit と concurrency limit

`RPC` の障害は、相手が遅いときだけ起きるわけではありません。トラフィックの急増でも起きます。ここで効くのが rate limit と concurrency limit です。

- rate limit
  単位時間あたりの request 数を制限する
- concurrency limit
  同時に処理中の request 数を制限する

前者は flood を防ぎやすく、後者は queue の伸びを防ぎやすいです。多くの system では両方を組み合わせます。`Inventory Service` が在庫 DB に重い lock を取りやすいなら concurrency limit が効きますし、public API の abusive traffic を抑えるなら rate limit が効きます。

#editorial_note[
  分散システムで「全部受けてから中で頑張る」は危険です。受け入れの境界で拒否する設計を持たないと、遅い request が queue を膨らませ、正常 request まで巻き添えにします。
]

== unary と streaming の使い分け

`RPC` というと unary request/response を思い浮かべがちですが、streaming は意外に重要です。注文システムでも、たとえば `Payment Service` と fraud engine のあいだで進捗付き審査を流したい場合や、`Order Service` から backoffice へ大量注文の status を順次流したい場合、streaming が向きます。

ただし streaming を使う理由は「かっこいいから」ではありません。主な利点は次の通りです。

- per-RPC の HTTP/2 ストリーム開始コスト（HEADERS frame）を複数メッセージで分散できる
- 部分結果や進捗を返せる
- 高頻度更新を 1 stream にまとめられる

一方で streaming は session lifetime の管理、flow control、片側 failure の扱いが難しくなります。過去 event を後から追いかけて読みたいなら、streaming ではなく `Kafka` のような log が向きます。

=== streaming は queue の代わりではない

ここは誤解しやすい点です。bidirectional stream があると「`Kafka` を使わず stream で流せるのでは」と思いがちですが、役割が違います。

- streaming
  生きている session 間で、いま発生している data を流す
- log / broker
  session をまたいで、後からでも読める形で data を残す

たとえば `Analytics Consumer` が 3 時間停止していたあとに過去 event を読み直したいなら、streaming は向きません。`Kafka` はこの用途のためにあります。

== tracing と metrics は一緒に設計する

`RPC` の observability で最初に必要なのは、`p95 latency` だけではありません。少なくとも次を揃える必要があります。

- success rate / error rate
- p50 / p95 / p99 latency
- timeout rate
- retry rate
- client-side queue wait
- server-side queue wait
- in-flight request 数

さらに tracing では、1 request が `Inventory Service`、`Payment Service`、DB にどの順で何ms使っているかを見えるようにします。checkout の tail latency を縮めるとき、どの hop が原因か分からなければ対処できません。

```text
trace: submit-order
  authn                12ms
  inventory.reserve    48ms
  payment.authorize   221ms
  db.tx                85ms
  write response       10ms
```

この程度の時系列が見えるだけでも、改善の方向性はかなり定まります。

=== 監視設計を先に持つ

設計段階で忘れやすいのが、「どの metric があればこの call chain を診断できるか」です。checkout path のような重要経路では、少なくとも次の組み合わせが必要です。

- `submit-order` 全体の p95/p99 latency
- `inventory.reserve` と `payment.authorize` の success/error/timeout
- client-side queue wait
- in-flight request 数
- retry count

これらが揃っていないと、`遅い` という報告が来ても、network なのか pool なのか downstream なのかを切り分けにくくなります。観測は実装後の飾りではなく、運用可能性の一部です。

=== deadline を hop ごとに伝える

timeout を各 service が勝手に持つだけでは、distributed call chain は安定しません。重要なのは、request 全体の deadline を hop ごとに伝え、各 hop が `残り時間` を見て振る舞うことです。

たとえば `submit-order` に 1500ms の overall deadline があるなら、`Order Service` は自分の手元時間を差し引いたうえで `Inventory Service` と `Payment Service` に短い budget を渡すべきです。これをしないと、上流は残り 200ms しかないのに、下流は 1 秒待つ、といった無意味な call が起きます。

```text
Deadline propagation example

Client deadline          t0 + 1500ms
API Gateway local work   80ms
Order Service receives   remaining 1420ms
Inventory call budget    250ms
Payment call budget      400ms
DB + response reserve    350ms
Jitter / retry reserve   420ms
```

この設計の価値は、速くすることだけではありません。どうせ成功しない request を早く諦め、queue と connection を守ることにあります。deadline は user 体験のためだけでなく、system 自身の保護装置でもあります。

=== tail latency と hedged request

`RPC` の世界では、平均より tail latency のほうが user 体験に効くことが多いです。1 台だけ遅い instance、1 回だけ重い GC、1 回だけ cold connection が混ざるだけで p99 は大きく悪化します。

一部の read-heavy system では、hedged request、つまり遅い call を見て別 instance へ予備 call を出す手法が使われます。ただし本書の継続例のように side effect を持つ call、特に payment や inventory reservation では慎重であるべきです。idempotency が強く担保されていないなら、hedging は重複実行の危険を広げます。

つまり tail latency 対策も、`読み取り` と `副作用つき書き込み` で同じではありません。

== service mesh が解決することと、しないこと

実務では `RPC` の運用に service mesh や共通 sidecar が入ることがあります。これにより mTLS、service discovery、retry、telemetry を統一しやすくなります。これは確かに便利です。

しかし mesh があっても、次の設計は依然として application 側の責務です。

- どの call を retry してよいか
- どの error を business error と見るか
- idempotency key をどう持つか
- degraded mode を何にするか

mesh は transport を助けますが、業務意味までは解釈しません。ここを誤解すると、「retry は mesh に任せたから安全」と思い込んでしまいます。

=== deploy 時の draining を軽視しない

同期通信では、普段の steady-state より deploy 時に事故が起きやすいことがあります。rolling update で instance を入れ替えるとき、古い instance への connection をどう drain するかを考えていないと、短時間の 5xx や timeout が急増します。

とくに注意が必要なのは次の場面です。

- keepalive 接続が古い instance に張りついたままになる
- long-lived stream が切断され、caller が大量再接続する
- readiness は落ちているが、in-flight request がまだ残っている
- autoscaling と rollout が重なり、rebalance 的な揺れが起きる

この種の障害は `business logic が壊れた` のではなく、通信面のライフサイクル設計が弱いことから起きます。同期 path が重要なほど、deploy は単なる配布作業ではなく通信イベントでもある、と見たほうがよいです。

=== cache と request coalescing

すべてを `RPC` で毎回取りに行く必要はありません。とくに read-heavy な依存先では、短い TTL cache や request coalescing が効くことがあります。たとえば商品メタデータや配送オプションのように、checkout で参照するが秒単位で変わらない情報です。

ただし cache を入れるときも、何を stale にしてよいかを定義する必要があります。inventory の残数や payment authorization の結果のように、鮮度が本質なものには雑な cache は危険です。逆に reference data には有効です。

request coalescing も同様で、同じ key への同時 request を 1 つにまとめることで downstream load を減らせますが、timeout 共有や head-of-line blocking の形で新しい難しさも入ります。結局ここでも、「何を共有してよいか」という設計判断が先にあります。

=== rollout と互換性

同期 `RPC` は、schema 変更の影響が比較的すぐに表面化します。したがって versioning と rollout の手順が重要です。基本は次の通りです。

- callee を先に前方互換にする
- caller をあとから切り替える
- 不要 field の削除は最後にする
- error contract の変更は特に慎重にする

とくに failure contract の互換性は見落とされがちです。新しい caller が `RETRYABLE_UNAVAILABLE` を期待しているのに、旧 callee は全部 `INTERNAL` で返す、といったズレがあると retry policy が壊れます。

=== call graph を短く保つ

実務では、`RPC` の問題の多くは 1 本の call の難しさではなく、call graph が長くなりすぎることから来ます。API Gateway -> Order Service -> Inventory Service -> Pricing Service -> Feature Flag Service -> User Segment Service のように深くなると、latency も failure surface も急増します。

checkout のような critical path では、次の原則が効きます。

- 依存先を増やしすぎない
- 同じ情報を複数 hop で取り直さない
- 必須でない副作用は同期 path から外す
- 失敗時に degraded でよい依存先を切り分ける

call graph を短くすることは、美学ではなく可用性の設計です。

=== 典型的な設定ミス

`RPC` が遅い、壊れやすい、と感じる system の多くは、理論より先に基本設定で失敗しています。よくあるのは次です。

- timeout が無い、または長すぎる
- caller と sidecar と gateway が多重に retry する
- connection pool が飽和しているのに見えていない
- business error と technical error が同じ status に潰れている
- 全依存先に同じ retry policy を使っている

この一覧は地味ですが、実務では非常に効きます。難しい pattern を導入する前に、まずここを潰すべきです。

== ケーススタディ 1: payment timeout が急増した日

checkout の p99 が急に悪化し、`payment.authorize` の timeout が増えたとします。このとき重要なのは、`payment が遅い` とだけ見ないことです。実際には少なくとも次の可能性があります。

- `Payment Service` 自身が遅い
- caller 側の connection pool acquire が詰まっている
- timeout が短すぎて、成功直前で切っている
- retry が多重化して、障害を増幅している

診断の順番としては次が分かりやすいです。

1. `payment.authorize` の success / error / timeout を見る
2. client-side queue wait と pool saturation を見る
3. retry count が跳ねていないかを見る
4. breaker が開いているかを見る
5. 直近 deploy / config change を確認する

この順で見れば、`network か payment か` という粗い分類より、`どこで待ち時間が積まれているか` へ近づけます。

=== ケーススタディ 2: inventory p99 は悪いが service 自体は healthy

`Inventory Service` 側の CPU も DB も平常なのに、`Order Service` から見ると inventory call の p99 だけが悪いことがあります。こういうときは server より caller 側を疑う価値があります。

典型的には次の形です。

```text
submit-order trace
  client-side queue wait    140ms
  network                     4ms
  inventory handler          18ms
```

この場合、原因は `Inventory Service` ではなく、caller 側で接続が取れず queue していることです。同期通信の運用では、`遅い RPC` を `遅い callee` と短絡しないことが重要です。

=== dependency ごとに予算表を持つ

checkout のような重要経路では、依存先ごとの `時間予算` と `失敗時の扱い` を小さな表にしておくと、レビューしやすくなります。

```text
Checkout dependency table

Inventory Service
  timeout: 250ms
  retry: 1
  idempotency: reservation_id based release
  degraded: no

Payment Service
  timeout: 400ms
  retry: very limited
  idempotency: required
  degraded: no

Recommendation Service
  timeout: 80ms
  retry: 0
  idempotency: n/a
  degraded: yes
```

この表があると、`全部同じ retry policy` や `全部同じ timeout` といった雑な設定を避けやすくなります。

=== 読み取り系と書き込み系を分ける

`RPC` 設計でとくに重要なのは、読み取りと書き込みを同じ政策で扱わないことです。商品情報取得や reference data lookup は、短い cache や場合によっては hedging が効きます。一方 payment authorization や inventory reservation は、重複実行の危険があるので極めて保守的に扱うべきです。

つまり `RPC` は 1 つの技術でも、`read RPC` と `write RPC` は実質別物です。timeout、retry、fallback の感覚も変わります。

=== fallback は成功ではない

運用で誤解しやすいのが、fallback を返した瞬間に `system は正常に成功した` と見てしまうことです。実際には、fallback は `完全な結果は返せないが、より悪い失敗を避けるために縮退した` という意味です。

継続例でも、たとえば recommendation や coupon suggestion の取得が落ちたときは fallback で checkout を続けてよいかもしれません。しかし inventory や payment で同じことはできません。したがって fallback の設計では、次を分けて考える必要があります。

- user-facing に欠けてもよい情報か
- あとから補完できる情報か
- business metric 上は `成功` と数えるのか
- product team と期待値が共有されているか

fallback は transport の工夫ではなく、業務上の `ここまでなら縮退で受け入れる` という合意です。

=== checkout path の運用レビュー質問

最後に、この章を設計レビューへ戻しやすいように、同期 path 向けの短い質問を並べます。

1. 各依存先に個別の timeout と retry budget があるか
2. client-side queue wait を観測できるか
3. breaker が開いたときの user-facing 振る舞いは決まっているか
4. deploy 時の draining と long-lived connection の扱いは明示されているか
5. 読み取り系と書き込み系で policy を分けているか

この 5 問に答えられない同期 path は、平常時は動いても障害時に崩れやすいです。

== 章末まとめ

`RPC` を運用するとは、network 越しの call を 1 本送ることではなく、動的な接続先と queue を制御することです。service discovery、load balancing、connection pool、retry budget、breaker、telemetry が一体であり、どれか 1 つだけ整っていても十分ではありません。

継続例の checkout path で重要なのは、`Inventory Service` と `Payment Service` を同じ「依存先」として雑に扱わないことです。latency も retry 可否も failure meaning も違う以上、同期通信の設定も分けて考える必要があります。

=== この章の設計判断の要点

`RPC` を運用するとは、client library を import することではありません。service discovery、balancing、connection queue、retry budget、breaker、tracing をまとめて設計することです。local call と違い、通信コストと failure mode が動的だからです。

注文システムの継続例で言えば、`Inventory Service` と `Payment Service` は単なる helper 関数ではありません。異なる throughput、異なる失敗、異なる retry 可否を持つ独立した依存先です。したがって `同じ RPC だから同じ設定` にしてはいけません。

#caution[
  `RPC framework が全部やってくれる` という期待は危険です。framework は transport を助けますが、retry 可否、error contract、budget 配分、degraded response の判断までは決めてくれません。
]

=== 演習

1. あなたの system で最も長い synchronous call chain を書き出し、user-facing request の SLO と見比べてください。
2. `Inventory Service` と `Payment Service` に同じ retry policy を適用してはいけない理由を説明してください。
3. client-side queue wait が p99 latency の大半を占めていた場合、どこを疑うべきか整理してください。
4. unary ではなく streaming を使う価値がある場面を、注文システム以外でも 2 つ挙げてください。

=== この章の出口

同期通信が「呼び出し」ではなく「動的な接続先と queue を持つ運用対象」だと見えたところで、今度は同期 path から外した仕事の置き場を考えます。次章では `Kafka` と log のモデルを使って、その逃がし先を整理します。
