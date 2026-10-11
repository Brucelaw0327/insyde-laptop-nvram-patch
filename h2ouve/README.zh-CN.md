# h2ouve/ -- 自备 H2OUVE

English version: [README.md](README.md)

H2OUVE 工具就放在这个文件夹里。**本仓库不附带任何二进制**——它们是
Insyde 的专有软件，再分发不是我们该做的事。

在应用 patch 之前（`run.cmd` 选 3），把下面这些文件放到这里：

| 文件 | 是什么 |
|---|---|
| `H2OUVE-W-CONSOLEx64.exe` | 变量编辑器（控制台版，x64） |
| `segwindrvx64.sys` | 它按需安装的内核驱动 |
| `segwindrv.cat` | 驱动的目录文件 / 签名 |
| `segwindrv.inf` | 驱动的 INF |
| `WDFInst.exe` | 随附的 WDF 安装辅助（可选） |

这个文件夹里的其他所有文件都是**本地生成的**，且已被 git 忽略：

- `vars_orig.txt` -- 你的第一次完整 NVRAM dump（`-gv`），回滚的源头
- `vars_before.txt` / `vars_after.txt` -- 一次写入运行的前/后快照
- `setup_new.txt` -- 实际写入的、打过补丁的记录文件
- `vars_new_full.txt` -- 打入单个字节补丁后的完整 dump
- `setup_undo.txt` -- 原始记录的逐字节副本，通用回滚件
- `undo_<slug>.txt` -- 同样的字节，按构建它的 patch 命名
  （`run.cmd` 选 4 优先用这个）

若缺最后三个文件，应用步骤（`run.cmd` 选 3 / `apply_patch.ps1`）会替你
生成：dump NVRAM 再调用 `mkrec.py`。

## H2OUVE 的获取途径

Insyde 不公开发布它。编写本仓库时核实过两个公开镜像；两者当时都在线，
且内容与 OEM 出厂镜像所带的一致（都与 Insyde 无关联）：

| 来源 | 内容 | 备注 |
|---|---|---|
| [`babybluue/insyde-h2o`](https://github.com/babybluue/insyde-h2o) | 全套装：console + GUI exe、驱动、cat/inf、WDFInst、release notes | 找到的最完整副本（2025） |
| [`xiaoMGitHub/LEGION_Y7000Series_Insyde_Advanced_Settings_Tools`](https://github.com/xiaoMGitHub/LEGION_Y7000Series_Insyde_Advanced_Settings_Tools) | console exe、驱动、cat/inf、WDFInst，外加 Legion 专属批处理 | 存续已久（2021）；忽略它的 `Execute.bat`——用本仓库的 `.cmd` 文件 |

给出链接不等于再分发：二进制特意留在仓库之外——它们是 Insyde 的财产。
下载、校验、本地保存。

### 使用前先校验

这个工具通过 SMM 与你的固件对话，被篡改的副本是严重风险。按以下顺序校验：

**1. 驱动才是真正的锚点。** 无论你运行哪个 exe，实际触碰固件的是
`segwindrvx64.sys`。它必须带有 *Insyde Software Corp.*（Taipei, TW）的
**Valid** Authenticode 签名；`segwindrv.cat` 必须带有 *Microsoft Windows
Hardware Compatibility Publisher*（WHQL）的 **Valid** 签名：

```powershell
Get-AuthenticodeSignature .\segwindrvx64.sys, .\segwindrv.cat
```

**2. exe 是没有签名的**（至少本方法所针对的这些构建没有）——没有签名可查，
所以改比哈希。本方法开发与验证时所用的那份副本：

```
H2OUVE-W-CONSOLEx64.exe   3592192 bytes
  SHA256  15ABA3D30DB28C784C7F8D5563196F7E22CB2BC7B97741DF17ECA07397ABE791
WDFInst.exe                246272 bytes
  SHA256  E36764851124EE882FCDF2BD9405C7086ECEE74FB7628A42BCAEE758477251E2
segwindrvx64.sys            93600 bytes
  SHA256  C3325ABAAE268555FB249DF4CBB6596E1FB74EC73EFFD451989A44C474D0B592
segwindrv.cat                9000 bytes
  SHA256  EAFBF94FA4206C66A4B6DDB3595CABADA49D7B28463B938DB0BDB74A3F24A417
segwindrv.inf                4036 bytes
  SHA256  F19FE4A6B630789085B47BC1558E24F9D275168874B9C0AA112448CDFE0AD589
```

```powershell
Get-FileHash .\* -Algorithm SHA256
```

哈希不同不必然是恶意的——Insyde 发布过许多 H2OUVE 构建版本——但那是一个
无人验证过的差异。要么驱动哈希对得上，要么自己读二进制；一个**既没有签名
又对不上哈希**的驱动就是恶意的，没有第二种解释。

## 关于正当性

用厂商服务工具编辑 UEFI 变量是正常的运维/维修操作。逆向它的*工作原理*并
把方法记录下来（这正是本仓库在做的事）没有问题。重新托管 Insyde 的二进制
则不然——所以这个文件夹只发布文档。
