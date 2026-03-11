#import "../theme.typ": editorial_note, checkpoint, caution

= はじめに

この文書は、Linux x86-64 上の network I/O を「`socket` を作る」「待つ」「再開する」という一本の線で整理するためのノートです。ネットワークを学ぶと聞くと、Ethernet frame、IP header、TCP header、routing table の図から入りたくなります。しかし user space の program から見ると、最初にぶつかる問いはもっと手前にあります。なぜ `accept` は待つのか。なぜ `read` は止まるのか。なぜ 1 本の thread で大量の socket を扱えるのか。なぜ Go では goroutine を connection ごとに作っても破綻しにくいのか。本書は、その問いに答えるための導入です。

`syscalls-process-primer` では、syscall、sleep、wakeup、scheduler の最小像を扱いました。一方で、`epoll` や async I/O の話は意図的に外しています。`go-runtime-primer` では `netpoll` が重要だと触れましたが、OS 側の network I/O の足場は深追いしていません。本書の役割は、その間を埋めることです。network I/O を「プロトコルの話」だけでなく、「どの実行主体が、いつ眠り、どの条件で起きるか」という low-level の話として見えるようにします。

== この教材の主題

本書の主線は次の 5 点です。

1. `socket` が file descriptor としてどう見えるか
2. blocking I/O と nonblocking I/O の違いは何か
3. `select` / `poll` / `epoll` が何を待ち合わせているのか
4. socket buffer、backlog、sleep/wakeup がどうつながるのか
5. その上に Go runtime の `netpoll` がどう乗るのか

この順序を取る理由は、いきなり `epoll` や `netpoll` へ飛ぶと、「何を登録して、何が ready になっているのか」が曖昧なままになるからです。まず `socket` と blocking I/O の手触りを作り、そのあとで nonblocking と readiness へ進みます。最後に user-space runtime の都合へ戻ると、goroutine ごとの見え方と kernel 側の待ち合わせをつなげて理解しやすくなります。

#checkpoint[
  本書を読み終えるころには、少なくとも次を説明できる状態を目指します。

  - listening socket と connected socket の違い
  - `O_NONBLOCK` と `EAGAIN` が意味すること
  - `select`、`poll`、`epoll` の役割差分
  - `readable` / `writable` が「完全に終わった」を意味しない理由
  - Go の network I/O が goroutine をどう止め、どう再開するかの概観
]

== なぜ今 network I/O を学ぶのか

低レイヤ学習では、CPU、メモリ、実行形式、syscall、runtime までは比較的一本の線に見えます。しかし network は別の島に見えやすいです。packet の図が多くなり、急に protocol 専門書の雰囲気になるからです。もちろん protocol は重要です。ただ、program を書く側が最初に知りたいのは、packet の bit 配置そのものよりも、「いまこの `read` がなぜ返らないのか」「複数 client をどう待つのか」「goroutine は本当に thread を占有していないのか」といった問いであることが多いです。

その意味で、network I/O は `syscalls-process-primer` の自然な次です。`read` と `write` を file に対して使うだけなら、blocking の感覚だけでもある程度進めます。しかし socket が相手になると、相手の速度、buffer の空き、接続待ち、再送、輻輳、wake up の契機が絡みます。ここで初めて、「I/O は単なる関数呼び出しではなく、待ち合わせを含む同期の問題だ」という実感が強くなります。

さらに Go runtime を読むときにも、この直感は効きます。goroutine が `net.Conn.Read` で止まったとき、本当に OS thread がそのまま寝ているのか。`netpoll` は何を poll しているのか。runtime は kernel の readiness 通知をどう user-space scheduler へ戻しているのか。この問いは、`epoll` と nonblocking socket の感覚なしには少し掴みにくいです。

== 対象と範囲

対象は Linux x86-64 に固定します。`socket` API 自体は POSIX 風ですが、`epoll` は Linux 固有ですし、Go runtime の network poller も OS ごとに backend が違います。初学段階では一般論を広げるより、1 つの具体環境で筋を通したほうが理解しやすいです。したがって本書では、Linux の `socket`、`fcntl(O_NONBLOCK)`、`select` / `poll` / `epoll`、`tcp(7)` / `udp(7)`、Go runtime の `netpoll` を主な足場にします。

一方で、初版では次を主題にしません。

- Ethernet、ARP、IP、TCP の全 header を bit 単位で読むこと
- kernel の TCP 実装 source を最後まで追い切ること
- NIC driver、DMA、割り込み処理、NAPI の細部
- TLS、HTTP/2、QUIC といった上位 protocol
- `io_uring` や completion-based I/O の深掘り

これらはすべて価値がありますが、最初の一冊で全部を同時に扱うと中心線がぼやけます。本書の初版は「user space の code から見た network I/O」と「それを支える待ち合わせ」の理解を優先します。

== 最初に持っておく直感

network I/O を理解するとき、最初に持っておくと楽な直感が 3 つあります。

第一に、socket も file descriptor の 1 種だということです。つまり user space から見れば、`read`、`write`、`close`、`fcntl`、`poll` のような既存の I/O API の枠内でかなりの部分が扱えます。もちろん内部実装は file と違いますが、入口の形が揃っていることは大きいです。

第二に、`readable` や `writable` は「全仕事が終わった」という意味ではないことです。`readable` は「少なくとも今なら 1 回は進めそう」という合図です。1 byte だけ読める場合もありますし、EOF が見える場合もあります。`writable` も「大きな payload を全部送り切れる」とは限りません。この直感がないと、event loop や `epoll` の説明が少し不思議に見えます。

第三に、network I/O は相手都合の待ち合わせだということです。file の `read` なら、ディスク cache や page cache の都合はあっても、概念上は「そこにある data を読む」感覚を持ちやすいです。socket は違います。相手がまだ送っていないかもしれないし、相手の受信 buffer が詰まっているかもしれないし、3-way handshake が終わっていないかもしれません。そのため、sleep と wakeup の話が中心へ出てきます。

#caution[
  本書では説明のために単純化したモデルを使います。たとえば `listen` backlog も最初は「`accept` 待ちの queue」として説明します。しかし実際の Linux TCP stack は handshake 中の queue や tuning parameter を含み、もう少し複雑です。ここでは細部の完全再現よりも、まず役割の違いを掴むことを優先します。
]

== 参照する一次資料

本書では、次の資料を主に参照します。

- `socket(2)`, `bind(2)`, `listen(2)`, `accept(2)`, `connect(2)`
- `read(2)`, `write(2)`, `fcntl(2)`
- `select(2)`, `poll(2)`, `epoll(7)`
- `tcp(7)`, `udp(7)`, `socket(7)`
- `strace`, `ss`, `tcpdump` の manual
- Go runtime の `netpoll` 関連 source と `go tool trace`

これらをそのまま読むと、API manual、kernel 都合、runtime 都合が散らばって見えます。本書ではそれらを「1 本の connection がどのように待たれ、どのように再開されるか」という軸で束ねます。

#editorial_note[
  network の学習で最初から packet header へ入りたくなる気持ちは自然です。ただ、socket を使う program の側から見ると、先に理解すべきなのは「いつ block するか」「誰が wake up するか」です。本書が `socket` と I/O の話から始めるのはそのためです。
]

== 各章の見取り図

本書は次の順で進みます。

1. まず `socket` と blocking I/O の最小像を作る
2. 次に nonblocking I/O と readiness の意味を整理する
3. その上で `select` / `poll` / `epoll` を比較し、event loop の形を見る
4. さらに backlog、buffer、sleep/wakeup、TCP/UDP の違いを最小限だけ押さえる
5. 最後に Go runtime の `netpoll` へ戻り、goroutine の待ち方とつなぐ

この順序には理由があります。`epoll` は魅力的ですが、その前に「何が block し、何を待っているのか」が見えていないと、単なる API 暗記になりやすいからです。次章ではその土台として、blocking socket を使った最小の server/client の流れから始めます。
