# 制作一个 patch（Making a patch）

> English: [making-a-patch.md](making-a-patch.md)

一个 **patch** 是一个小文本文件，内容是：*在这个变量存储里、这些记录中，把这个字节从 A 改成 B*。同一套工具的不同用途之间，唯一不同的就是它——闸门逻辑、快照、写入、读回验证、撤销全部相同。

这正是要点：偏移和取值住在一个你可以阅读、编辑、审阅的文件里，而不是埋在脚本里。

---

## 1. 格式

```
NAME     = fTPM -> Disable
VARSTORE = SystemConfig
GUID     = A04A27F4-DF00-4D42-B552-39511302113D
RECORDS  = Setup,Custom

OFFSET   = 0x100          # 一处改动，写成三个键
FROM     = 0x02
TO       = 0x00
```

多字节写法（一个 patch 改几个字节）：

```
CHANGE   = 0x100 0x02 0x00     # OFFSET FROM TO
CHANGE   = 0x2A0 0x01 0x00
```

规则：

- `#` 开头是注释——整行，或行内空白之后。
- 键名不区分大小写；值为十六进制，带不带 `0x` 都行。
- `GUID` 带不带花括号都可以。
- `VARSTORE` 是自由文本，只用在日志里；真正标识存储的是 `GUID`，因为名字跨厂商不唯一。
- `RECORDS` 必填：它指名该存储**里面**的记录。本项目的 H2OUVE 转储中 SystemConfig 存储用 `Setup,Custom`；其他存储用别的名字。
- `OFFSET/FROM/TO` 与 `CHANGE` **互斥**。混用是报错，不是猜。

解析器会大声拒绝：缺 GUID；GUID 格式错；缺 RECORDS；非十六进制值；`CHANGE` 不是三个 token；同一偏移出现两次；以及 `FROM == TO`（一个什么都没改的 patch）。

## 2. 这些数字从哪来

`tools/ifr_locate.py` 从你自己的固件推导它们，并打印一个可直接保存的 patch 存根：

```
> python tools\ifr_locate.py find Setup.bin "Trust Platform Module"
  ...
# --- candidate patch file (verify by eye before use) ---
# Advanced / Trust Platform Module
NAME     = Trust Platform Module -> Disable
VARSTORE = SystemConfig
GUID     = A04A27F4-DF00-4D42-B552-39511302113D
RECORDS  = Setup,Custom
OFFSET   = 0x100
FROM     = 0x2
TO       = 0x0
```

存根只是**建议**。保存前读一遍——尤其确认它标成 `TO` 的取值真的是你想要的。然后在写任何东西之前，用真实转储证明它：

```
> python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
RESULT: consistent -- the IFR layout explains this dump
```

`verify` 失败意味着偏移不是你以为的那个。不要写。

提示：菜单 `run.cmd` 选项 2 会代劳整个"解包 → 定位 → 生成存根"流程；关键词留空还能列举固件里所有可定位的设置，按编号挑选。

## 3. 执行一个 patch

```
powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\<name>.patch
```

`run.cmd` 选项 4 就是以菜单方式运行同一条命令，带 patch 选择器、键入确认和自提权。

写入之前，无论 patch 内容是什么，`apply_patch.ps1` 都跑同一组闸门：

| 闸门 | 检查什么 | 退出码 |
|---|---|---|
| 身份 | BIOS / 主板 / 机型 与 `machine.txt` 一致 | 7（缺 `machine.txt` 时为 6） |
| BitLocker | 没有任何卷是 TPM 保护的 | 11（无法判定时 12） |
| 布局 | 实机记录的 `Attributes`/`DataSize` 与补丁后的记录文件一致 | 8 |
| 合理性 | 记录文件里确实是本 patch 的目标值 | 5 |
| 盲写 | 当前值写入前可读 | 4 |

`-Force` 会**一次性**跳过所有闸门。它为已经进不了卷的操作者而存在，不是便利开关。

应用前先看 patch 会做什么：

```
powershell -ExecutionPolicy Bypass -File check_status.ps1 -Patch patches\<name>.patch
```

`run.cmd` 选项 3 通过菜单做同一件事，让只读报告解释的正是写入器将碰的那个字节。

## 4. 撤销

```
run.cmd 选项 5                              # 或者：
powershell -ExecutionPolicy Bypass -File restore_original.ps1 -Patch patches\<name>.patch
```

`restore_original.ps1` 写回 `h2ouve\undo_<slug>.txt`——本 patch 碰过的记录的原始字节，取自第一份转储。该文件缺失时回退到 `h2ouve\setup_undo.txt`（通用回滚副本）。

回滚只**报告** BitLocker、不闸它：如果一个卷已经躺在恢复模式里，把 TPM 放回去才是修复。

## 5. 一次一个 patch——为什么

`setup_new.txt` 永远从 `h2ouve\vars_orig.txt`——**干净的**第一份转储——重建。如果记录文件存在但不含当前 patch 的目标值，`apply_patch.ps1` 会自动重建而不是写陈旧字节。

这个后果值得说破：一次写入只携带*当前*这个 patch 的改动，所以 patch A、B 碰到相同记录时，先应用 A 再应用 B 会**把 A 撤掉**。这是故意的——记录文件永远表示"干净状态 + 恰好这些字节改动"，这是唯一能被安全验证和回滚的东西。

要一次改多个字节，放进**同一个** patch：

```
CHANGE   = 0x100 0x02 0x00
CHANGE   = 0x2A0 0x01 0x00
```

`mkrec.py`（脚本会调用）一次过全部应用并逐一复核。

## 6. 已移除的旧路径

更早的版本从 `machine.txt` 读偏移（`TARGET_OFFSET/FROM/TO`，或 `FTPM_OFFSET/ON/OFF`），还带一个内置的兜底提示。那条路**没了**：字节改动只能由 patch 文件描述，句号。`machine.txt` 现在只做身份闸门。原因：藏在一个 git 忽略的本地文件里的偏移无法 diff、无法审阅，而内置提示就是某一家固件布局披着通用外衣。

## 7. 本仓库的更早版本

在 patch 文件之前，偏移以 `FTPM_OFFSET/ON/OFF` 的形式住在 `machine.txt` 里，两个引擎叫 `disable_ftpm.ps1` / `restore_ftpm.ps1`。这两个在本版本都已移除；脚本改成了通用名（`apply_patch.ps1` / `restore_original.ps1`）并接受 `-Patch`，中间版本预置的 `patches\ftpm-*.patch` 也已删除——偏移请从你自己的固件推导。
