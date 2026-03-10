#import "../theme.typ": checkpoint, caution

= syscall path

権限境界が見えたら、次は user program が kernel に仕事を頼む入口を見ます。本章の主題は syscall です。特別な命令や trap を使って kernel へ入り、引数を受け取り、kernel 側 handler を dispatch し、結果を user に返すまでを一本の流れとして整理します。

#checkpoint[
  この章の到達点は次の通りです。

  - syscall の entry / dispatch / return を分けて説明できる
  - user ABI と kernel 内部表現をどう橋渡しするか分かる
  - `copyin/copyout` が必要な理由を説明できる
  - trap return と syscall return の共通点と違いを説明できる
]

== syscall は「特別な関数呼び出し」ではない

見た目は関数呼び出しに似ていますが、syscall は普通の call ではありません。なぜなら、呼び出し先が別 privilege level にあり、address space 保護の境界を越えるからです。user 側は number と引数を決められた register へ載せ、専用の入口命令を叩きます。kernel 側はそれを受け取って内部 handler へ振り分けます。

この時点で重要なのは、user ABI と kernel 内部 API は同じでなくてよいことです。user 側では register と integer で渡しても、kernel 側では trap frame や syscall context として一度まとめ直したほうが扱いやすいです。

== entry で何を保存するか

syscall entry 直後の最優先事項は、user 文脈を壊さず保存することです。最低限必要なのは次です。

- user `rip`
- user `rsp`
- flags
- syscall number
- 引数 register

実際の x86-64 Linux では、専用の syscall ABI と machine-specific な保存規約があります。本書の toy kernel では、それを trap frame にまとめて「今どの process が、どの引数で kernel に入ったか」を表現できれば十分です。

== dispatch table

entry が済んだら、次は syscall number を見て handler へ振り分けます。最小モデルでは、固定長の dispatch table が分かりやすいです。

```c
static sys_fn table[] = {
  [SYS_write] = sys_write,
  [SYS_exit]  = sys_exit,
  [SYS_fork]  = sys_fork,
  [SYS_exec]  = sys_exec,
  [SYS_wait]  = sys_wait,
};
```

この形を取ると、syscall は「user が直接 kernel 内関数を呼ぶ」のではなく、「番号で表された要求を kernel が解釈して処理する」ことが見えます。これは security 的にも実装整理としても重要です。

== `copyin/copyout` はなぜ必要か

syscall の引数が integer だけなら簡単ですが、多くの syscall は user buffer や文字列 pointer を受け取ります。ここで kernel は、user が渡した pointer をそのまま無条件には信用できません。まだ map されていないかもしれませんし、kernel 領域を指しているかもしれませんし、途中で page fault するかもしれません。

そこで `copyin/copyout` が必要になります。つまり「user pointer を検証し、必要なら fault を扱いながら kernel 安全領域へコピーする」処理です。これがあるから、syscall 境界は単なる関数呼び出しではなく、保護境界として意味を持ちます。

== 返り値と失敗

syscall は常に成功するとは限りません。最小モデルでも、少なくとも次の失敗を扱います。

- 未知の syscall number
- user pointer 検証失敗
- resource 不足
- 存在しない child への `wait`

返り値は通常 register に載せて user へ返しますが、重要なのは「failure を表す一貫した規約」を持つことです。Linux では `-errno` 系の規約がありますが、toy kernel では負値や明示的エラーコードでも構いません。大事なのは境界で一貫していることです。

== syscall return

handler が終わったら、kernel は user 文脈へ戻ります。このとき、「同じ process へすぐ戻る」のか、「scheduler を挟んで別 process へ行く」のかはまだ確定していません。つまり syscall return は、単なる epilogue ではなく scheduler と接続する分岐点です。

この視点はかなり重要です。syscall から戻る経路と timer interrupt から戻る経路は、最後に user 文脈へ戻るという意味では似ています。違いは、その前にどこまで process 管理の判断を挟むかです。

== `write` と `exit` から始める理由

最初の syscall としては `write` と `exit` が教材向きです。

- `write`
  user buffer を kernel へ安全に渡す必要がある
- `exit`
  process lifecycle に直結する

この二つだけでも、copyin、返り値、process 終了、親側回収の必要性がかなり見えます。本書ではそこへ `fork`, `exec`, `wait` を足して process 本体へ進みます。

#caution[
  syscall 実装の最初の失敗は、handler 本体より user pointer 検証の抜けです。user buffer を kernel で直接 dereference してしまうと、保護境界の意味が崩れます。`copyin/copyout` を syscall path の一部として最初から考えるのが安全です。
]

== この章の出口

ここまでで syscall は一本の path として見えました。しかし process 本体はまだ曖昧です。次章では、trap frame と kernel stack を持つ実行主体として process を定義し、`exec` で新しい image をどう作るかを見ます。
