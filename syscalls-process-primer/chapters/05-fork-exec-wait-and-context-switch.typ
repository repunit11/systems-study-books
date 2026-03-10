#import "../theme.typ": checkpoint, caution, editorial_note

= `fork`、`exec`、`wait`、context switch

process と address space が見えたら、最後に process lifecycle を閉じます。本章では `fork`、`exec`、`wait` を主線に、context switch と scheduler の最小像を整理します。目標は、「どの瞬間に process が増え、どの瞬間に image が入れ替わり、どの瞬間に実行主体が切り替わるか」を混同せず説明できるようになることです。

#checkpoint[
  この章の到達点は次の通りです。

  - `fork` と `exec` の役割分担を説明できる
  - context switch と trap return の違いを説明できる
  - `wait` と zombie が必要な理由を説明できる
  - process lifecycle を syscall と scheduler の両方から見られる
]

== `fork` は何を複製するか

`fork` の最小意味は、「今の process によく似た新しい process を作る」です。最も素朴な実装では、親の address space を丸ごと複製し、trap frame もほぼコピーします。違いは戻り値だけです。親には child PID、子には 0 を返します。

この設計が Unix っぽいのは、`fork` が「新しい image を指定しない」点にあります。いったん今の実行状態を複製し、その後に必要なら child 側で `exec` を呼んで別 image へ移ります。この二段階が process 制御を柔軟にしています。

== copy-on-write は改善策であって本質ではない

production OS は `fork` のたびに全 address space を丸ごとコピーしません。copy-on-write を使い、実際に書き込みが起きるまで page を共有します。しかし教材として最初に大切なのは最適化ではなく、「`fork` は execution context を複製する」という意味です。copy-on-write はその高価さを和らげる改善策です。

したがって本書では、本質を次のように押さえます。

- 親と子は最初ほぼ同じ user image を持つ
- 戻り値だけが違う
- scheduler は以後それぞれを独立 process として扱う

== `exec` は process を消さず image を替える

`fork` で child を作ったあと、典型的には child が `exec` を呼んで別プログラムへ入れ替わります。ここで重要なのは、`exec` は PID を変えないことです。つまり、親から見ると「同じ child process が別 program になった」だけです。

この `fork` + `exec` の分業があるから、shell は child を作ってからその中身だけ差し替えられます。もし `exec` が新 process 生成まで兼ねていたら、親子関係や待ち合わせの構図はかなり変わってしまいます。

== context switch は何を切り替えるか

context switch は「今 CPU に乗っている kernel 実行文脈を別 process の文脈へ切り替える」処理です。ここで混同しやすいのは、syscall return との違いです。

- trap return:
  同じ process の user 文脈へ戻る
- context switch:
  どの process を次に走らせるかを変える

つまり context switch は scheduler 判断を伴います。保存するのは current の kernel 側状態、復元するのは next の kernel 側状態で、その先に trap frame を経由して user mode へ戻るかどうかが決まります。

== scheduler の最小像

本書で必要な scheduler 像は最小限で十分です。次の構造があれば process lifecycle を説明できます。

- runnable queue
- current process
- sleep / wake の仕組み
- timer interrupt などの再スケジュール契機

この最小像があると、`wait` で親が sleep し、child の `exit` で wake される流れが自然に見えます。`go-runtime-primer` の scheduler と比べると、こちらは kernel が process を直接切り替える世界だと分かります。

== `exit` と zombie

process が終了しても、その場で process 構造体を完全に消すわけにはいきません。親が終了コードを回収する前に全部消すと、`wait` が何も知れなくなるからです。そこで process はいったん zombie 状態になります。これは「実行は終わったが、親への報告がまだ残っている」状態です。

この設計は一見地味ですが、Unix process モデルのかなり本質です。親子関係があるからこそ、終了情報の受け渡しも process 管理の一部になります。

== `wait` は何を待つか

`wait` は child の終了を待ち、その終了コードを回収します。child がまだ走っていれば親は sleep し、child が zombie になったら回収して返ります。ここで scheduler と process table が再び接続します。単なる polling ではなく、「親を寝かせ、子の終了で起こす」という同期だからです。

この構造を持つと、`wait` は単なる便利 API ではなく、process lifecycle を閉じるための仕組みだと分かります。

#editorial_note[
  Linux の実際の process 管理は、signal、thread group、namespace、fd table 共有など、ここで扱わない要素が大量にあります。本書の役割は、それらの前にある最小骨格を見せることです。`fork/exec/wait` と context switch の関係が見えれば、巨大な source tree でも入り口を失いにくくなります。
]

#caution[
  `fork`、context switch、syscall return を全部「戻る処理」とひとまとめに覚えると混乱します。`fork` は実行主体の複製、context switch は current/next の入れ替え、trap return は user mode への出口です。似た register 保存をしていても、意味は別です。
]

== この章の出口

ここまでで user/kernel 境界の最小 process 世界は閉じました。user mode へ降りる、syscall で入る、`fork` で増える、`exec` で入れ替わる、`wait` で回収する。この一連が見えると、OS 側の process 管理と user-space runtime の責務分担もかなり分かりやすくなります。
