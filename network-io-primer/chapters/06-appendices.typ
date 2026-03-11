#import "../theme.typ": checkpoint, editorial_note, caution, terminal

= 付録と次の一歩

本編では、`socket`、blocking / nonblocking I/O、`select` / `poll` / `epoll`、socket buffer、Go runtime の `netpoll` を一本の線で整理しました。この章では、復習、観測コマンド、用語、よくあるつまずき、短い演習、次に読む資料をまとめます。新しい topic を増やすというより、「ここまでの理解を手元で確かめ、次へ伸ばす」ための章です。

#checkpoint[
  この章では次を押さえます。

  - 各章の復習ポイント
  - 手元で観測するときの最小コマンド群
  - よく混乱する用語と誤解
  - 次に読むとよい manual / source / 文書
]

== 章ごとの復習ポイント

ここまでの内容を短く戻すと、各章の核は次のように整理できます。

- 導入:
  network I/O は protocol の話であるだけでなく、待ち合わせと再開の話でもある
- blocking I/O:
  listening socket と connected socket を分け、`accept` / `read` / `write` が sleep し得ることを見る
- nonblocking:
  `O_NONBLOCK` と `EAGAIN` により、待ちを user space 側へ戻す
- multiplexing:
  `select` / `poll` / `epoll` は複数 fd の readiness をまとめて待つ
- kernel bridge:
  backlog、buffer、backpressure、wake up、`netpoll` が一続きで見える

この順序を持っているだけで、network I/O の学習はかなり迷いにくくなります。`epoll` の man page を読んでも、「これは readiness の登録 API だ」「completion を返すわけではない」と整理しやすくなります。

== 観測コマンドの導線

理解を定着させるには、短い program を動かして system call と socket 状態を見るのが有効です。最小の導線としては次が便利です。

```text
$ strace -f -tt -e trace=network,epoll_ctl,epoll_wait,read,write ./server
$ ss -ntlp | grep 8080
$ lsof -iTCP:8080 -n -P
$ tcpdump -i lo tcp port 8080
$ go test -trace trace.out ./...
$ go tool trace trace.out
```

`strace` は「どの syscall で待っているか」を見る入口です。blocking server なら `accept` や `read` で止まり、`epoll` server なら `epoll_wait` を中心に見えるはずです。`ss` や `lsof` は listening 状態や established connection を観察するのに役立ちます。`tcpdump` は loopback 上でも packet の往復を見せてくれるので、`read` が返る前に何が飛んでいるかの感覚を持ちやすくなります。Go 側は `go tool trace` が、goroutine の block/unblock と scheduler の動きを見る入口になります。

== 小さな観測課題

次の順で短い観測課題を試すと、本編の概念がかなり手元に定着します。

1. blocking echo server を作り、1 client が黙っていると他が止まることを確認する
2. 同じ server を thread-per-connection にして、単純だが thread 数が増えることを確認する
3. socket を nonblocking にし、`EAGAIN` が普通に返ることを観察する
4. `poll` あるいは `epoll` 版へ書き換え、待ちが `epoll_wait` へ集約されることを `strace` で見る
5. Go 版 echo server を `trace` し、goroutine が I/O 待ちで park/unpark される様子を眺める

ここで大切なのは、大きな benchmark を走らせることではありません。短い program で「いま何を見たいのか」をはっきりさせることです。観測結果を source や manual のどこへ戻すかが分かれば十分です。

== 用語小事典

- file descriptor
  user space から I/O 対象を指す整数ハンドル
- listening socket
  新しい接続を受け取る入口になる socket
- connected socket
  接続後の実データ送受信用 socket
- blocking I/O
  条件が整うまで caller を sleep させる I/O
- nonblocking I/O
  進めないときは sleep せず、`EAGAIN` などで caller へ戻す I/O
- readiness
  「今なら少なくとも 1 回は block せず進めそう」という状態
- backpressure
  下流の遅さが上流の進みを抑える現象
- backlog
  `listen` 側の接続待ち capacity に関わる量
- level-triggered
  条件が成立している間は event が返り続け得るモデル
- edge-triggered
  状態変化の瞬間を中心に event を返すモデル
- `netpoll`
  Go runtime が network fd readiness と goroutine scheduler を結ぶ仕組み

== よくあるつまずき

== `readable` なら 1 request 全体を読めると思ってしまう

そうではありません。`readable` は socket buffer の状態変化を示すだけです。TCP は byte stream なので、application message の境界は自分で復元する必要があります。

== nonblocking は busy loop だと思ってしまう

違います。正しい nonblocking I/O は poller と組み合わせます。`EAGAIN` が返ったら、何度も空打ちするのではなく、ready になるまで別の仕事へ移るのが基本です。

== `epoll` があれば state machine は不要だと思ってしまう

不要にはなりません。`epoll` は ready fd を返すだけです。どこまで parse 済みか、返信が何 byte 残っているか、timeout をどう扱うかは application state の責務です。

== Go では `epoll` を意識しなくてよいと思ってしまう

普段の application code では直接触れなくてよい場面が多いですが、性能問題や block の原因を理解するときには土台のモデルが効きます。runtime が readiness を隠してくれているだけで、待ち合わせ自体が消えるわけではありません。

== `writable` なら全部送れると思ってしまう

これも違います。send buffer の空きは有限です。大量送信では short write や `EAGAIN` が普通に起きるので、未送信 data の管理が必要です。

#caution[
  `epoll` を使うだけで program が自動的に速くなるわけではありません。application protocol が重い、送信 queue が巨大、timer 管理が雑、lock contention が大きい、といった別の要因はそのまま残ります。
]

== 短い演習案

- 演習 1:
  blocking echo server を書き、`nc` を 2 つ開いて片方を黙らせたときの挙動を説明する
- 演習 2:
  同じ server を nonblocking + `poll` で書き直し、`EAGAIN` の出方を確認する
- 演習 3:
  `epoll` server で `EPOLLOUT` を常時監視した版と、未送信 data があるときだけ監視する版を比較する
- 演習 4:
  Go で connection ごとに goroutine を立てる server を書き、`go tool trace` で block/unblock を観察する
- 演習 5:
  TCP と UDP の echo server を両方書き、message 境界の違いを説明する

これらの演習は「全部完成させる」ことより、「何が難しいのか」を言葉にできることが大切です。たとえば `epoll` server が難しいなら、parser と送信 queue が必要になる点を説明できれば十分に前進しています。

== `syscalls-process-primer` と `go-runtime-primer` へ戻る読み方

本書を読み終えたら、既存シリーズへ戻ると見え方が変わります。

まず `syscalls-process-primer` へ戻ると、sleep/wakeup、scheduler、wait queue の説明が network I/O と直結して見えます。`read` が止まること、`epoll_wait` がまとめて待つこと、wake up が条件変化で起きることが、抽象論ではなく具体例になります。

次に `go-runtime-primer` へ戻ると、`netpoll` が突然出てくる謎の部品ではなくなります。Go runtime は kernel readiness を受け取り、goroutine を park/unpark する橋として `netpoll` を使っています。つまり本書の知識は、そのまま runtime 読解の前提になります。

== 次に読むなら

本書の次に進む方向は大きく 4 つあります。

- protocol を深める:
  TCP の輻輳制御、再送、flow control、HTTP/TLS へ進む
- kernel を深める:
  Linux network stack、socket internals、NAPI、driver 方向へ進む
- runtime を深める:
  Go の `netpoll` 実装、scheduler、timer との協調を source で追う
- API を広げる:
  `io_uring`、`kqueue`、IOCP など readiness/completion の比較へ進む

最初の一冊で全部へ行く必要はありません。むしろ「待つとは何か」「ready とは何か」を 1 本持っておくと、どの枝へ行っても学習しやすくなります。

== 参考資料

- `socket(2)`
- `socket(7)`
- `tcp(7)`
- `udp(7)`
- `select(2)`
- `poll(2)`
- `epoll(7)`
- `strace(1)`
- `ss(8)`
- Go runtime の `netpoll` 関連 source
- `go tool trace`
- `The Linux Programming Interface`
- `UNIX Network Programming`

#editorial_note[
  network I/O は一見すると API の数が多く、protocol の細部も多いので散らばって見えます。しかし中心にある問いは比較的単純です。今は進めるのか、待つべきなのか、誰が起こすのか。本書はその 3 つの問いを揃えることを目指しました。
]

= おわりに

network I/O を理解するために、最初から巨大な protocol 図や kernel source 全体図が必要なわけではありません。まずは `socket` を作り、block し、nonblocking にし、ready を待ち、再開する、という一連の流れを掴むことが大切です。その流れが見えると、`epoll` も Go の `netpoll` も急に別世界の技術ではなくなります。

一度この地図を持つと、C の event loop を書くときも、Go の goroutine server を読むときも、「いまは待ち合わせのどの層を見ているのか」を言葉にしやすくなります。そこまで来れば、次は protocol、kernel、runtime のどの方向へ進んでも、理解を積み上げやすくなります。
