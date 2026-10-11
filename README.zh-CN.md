# insyde-laptop-nvram-patch

> [English](README.md) | 简体中文

在 **Insyde H2O** 机器上，从 Windows 改那些 BIOS Setup 界面里看不到的固件
设置：直接编辑承载该设置的 UEFI 变量，走的是厂商自己的 SMI 服务通道
（H2OUVE）。不刷 BIOS、不清 CMOS、不在 BIOS 菜单里大海捞针。为**笔记本**
而生：OEM 笔记本的 Setup 界面把大多数开关都藏了，台式机主板通常直接暴露、
基本用不上这套东西。

工作的基本单位是一个小的文本文件——**patch**——写明变量存储区、里面的
记录、以及要搬动的字节。`apply_patch.ps1` 在身份 / 布局 / BitLocker 三重
闸门后面应用一个 patch，写入后回读校验，并生成 undo 文件；
`restore_original.ps1` 负责回滚。

文档通篇的 **worked example 是关闭 AMD 固件 TPM（fTPM）**。在很多消费级
笔记本上，这一项在 BIOS Setup 界面里根本不存在，常见的绕行路线也全是死
胡同：`Setup` 变量对 OS 写保护、`dmpstore` 失败、只枚举标准 AMD CBS/PBS
页面的工具根本翻不出 TPM 页。其他任何设置都是同样三步、换一个自己的
patch 而已——见 [`docs/making-a-patch.md`](docs/making-a-patch.md)。仓库
**不附带任何现成 patch**：一个 patch 描述的是某一个固件 build 的布局，
预制的那个在别人机器上就是一个自信标错了的字节。

> **这会改写固件 NVRAM，可能把机器变成砖。**
> 运行任何东西之前，先读 [`DISCLAIMER.md`](DISCLAIMER.md) 和
> [`docs/how-it-works.md`](docs/how-it-works.md)。
>
> **先关掉 BitLocker 和其他依赖 TPM 的功能**——见
> [开始之前](#开始之前)。没有 TPM，OS 卷下次开机会进入恢复模式。

---

## 开始之前

fTPM 是这台平台上唯一的 TPM。**关掉之后，OS 就完全看不到 TPM 了**，一切
把密钥封进 TPM 的东西都会失效。这部分要先做，否则 apply_patch.ps1 会
拒绝运行。

**1. 先解决 BitLocker / 设备加密（强制）。**

```powershell
manage-bde -status                    # 有卷被保护吗？
manage-bde -off C:                    # 解密（慢，但最稳）
# 或者保持加密、只解除一次开机的 TPM 锁：
manage-bde -protectors -disable C:    # 开机后再重新启用
```

被 TPM 保护的卷一旦失去 TPM，就会以**恢复模式**启动。如果你手里有恢复密钥
也愿意手动输入，可以跳过这步、带 `-Force` 跑 apply_patch.ps1——但这个
决定脚本不会替你做。

**2. 知道还有哪些东西依赖 TPM。** 这些不会把你锁在门外，所以脚本只报告、
不拦截，但请预期它们的状态会丢失：

| 功能 | 后果 | 位置 |
|---|---|---|
| Windows Hello（PIN / 指纹 / 人脸） | 登录密钥封在 TPM 里——需要重新录入 | 登录选项 |
| Credential Guard / VBS 密钥 | 封在 TPM 里——丢失 | `Win32_DeviceGuard` |
| HVCI（内核内存完整性） | 仅报告；证明机制没有 TPM 可用 | `Win32_DeviceGuard` |
| 任何把密钥存在 TPM 里的应用 | 该密钥无法找回 | 视应用而定 |

动手前先跑 `run.cmd` 选 1（只读探针），以上
信息它都会列出来。

**3. 留好回滚路径。** `run.cmd` 选 5 会把原始字节写回去；请保管好首次
写入时生成的 `h2ouve/undo_<slug>.txt`（见[回滚](#回滚)）。

**关于 `-Force`。** `apply_patch.ps1 -Force` 会一次性越过**所有**闸门——
身份、布局和 BitLocker。它存在的理由是：已经被锁在卷外的操作者，仍需要
一个在机器指纹不再匹配时能动手的途径；它不是便利开关。如果某个闸门拦下
了你，而你的第一反应是加 `-Force`——那正是停下来读闸门信息的时刻。

---

## 一个菜单，三个引擎

双击 **`run.cmd`**；所有操作都收拢在它的菜单里：

| 菜单项 | 实际执行的 | 效果 |
|---|---|---|
| 1 — 状态探针 | `check_status.ps1 -Dump` | 只读：身份、BitLocker、TPM 依赖项。首次运行自动生成 `machine.txt`，随后刷新现场 NVRAM dump（`h2ouve\vars_live.txt`，选项 2 复用它显示 `now=` 现值）。**任何时刻都安全。** |
| 2 — 在固件里定位设置 | `tools\ifr_locate.py extract` + `find --out` | 只读：把 BIOS 升级包一路解到 Setup 模块，解码 IFR，写出候选 patch。关键词留空 = 列出全部设置（带现值/默认值），输编号即选中 |
| 3 — 针对某个 patch 的探针 | `check_status.ps1 -Patch <文件> -Dump` | 额外显示所选 patch 将改动的现场字节；同样会刷新 `h2ouve\vars_live.txt`。**任何时刻都安全。** |
| 4 — 应用一个 patch | `apply_patch.ps1 -Patch <文件>` | **改 NVRAM**——列出 `patches\*.patch` 供选择，要求键入 `YES` 确认，自动提权 |
| 5 — 回滚（撤销） | `restore_original.ps1 -Patch <文件>` | **改 NVRAM**——把原始记录写回去 |

也可以直接跑引擎：

```powershell
powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\my-setting.patch
```

## 一次运行做了什么

`apply_patch.ps1` 应用**一个 patch**，且拒绝任何猜测。顺序如下：

1. **G——身份闸门**：本机的 BIOS / 主板 / 型号必须与 `machine.txt` 一致
   （不符 exit 7；文件缺失 exit 6——只读探针会生成它，写入引擎绝不代劳）。
2. **P——patch**：由 `lib/patchfile.ps1` 解析，这是所有脚本共用的唯一
   解析器（文件不合法 exit 2）。
3. **G2——BitLocker 闸门**：不允许任何卷处于 TPM 保护中（exit 11），且
   BitLocker 状态必须可读（exit 12）。
4. **B——引导构建**：记录文件缺失或属于别的 patch 时，dump NVRAM 并从
   最初的原始 dump 重建。
5. **0 / 0b——快照 + 布局闸门**：先快照，再核对现场记录与 patch 所针对的
   布局一致。
6. **1–4——写入并证明**：读测试、写入、重新 dump、逐字节验证；最小记录
   没生效时自动改用完整 dump 重试。

然后提醒你**完全关机**——该设置在上电时才被消费，热重启不够。

## 它**不是**什么

- 不是刷 BIOS。固件镜像分毫未动，只有 NVRAM 变量存储区变了，BIOS 版本
  字符串不会变。
- 不是厂商专属魔法。它是一套有文档的方法加脚本；有意思的部分在于
  *偏移量是怎么找到的*——`tools/ifr_locate.py` 从你自己的固件里推导出来，
  而不是相信一个写死的常数。
- 不是 TPM "清除"。什么都不擦除，TPM 只是停止向 OS 发布。
- 不是通用 UEFI 变量编辑器。它只搬动你点名的字节，并且在无法确认自己
  正站在 patch 所针对的那台机器、那套记录布局上时拒绝运行。

## 环境要求

- Windows，以 **UEFI** 模式启动（不是 legacy）。
- **Insyde H2O** 固件，且通过同一 SMI 通道暴露变量存储区。fTPM 示例还需要
  一块带 fTPM 的 **AMD** 平台；它的偏移量（`0x100`）是某一个固件家族的
  布局——**务必从你自己的固件里推导**（见*定位你自己的偏移量*）。
- **管理员**权限（启动器会自行提权）。
- **没有活动的 TPM 保护**——BitLocker / 设备加密已关闭（或已挂起），
  否则脚本拒绝写入；见[开始之前](#开始之前)。
- Python 3——**已内置**在 `tools\runtime\python`（embeddable 3.13.16，
  PSF 许可，见 `tools\runtime\python\LICENSE.txt`），无需安装；若删掉
  该目录则回退用 `PATH` 上的 `python` / `py -3`。
- **H2OUVE** 工具——**不随仓库发布**；获取途径与校验方法见
  [`h2ouve/README.md`](h2ouve/README.md)。

---

## 快速上手

以关 fTPM 为例走完全程（其他设置在自己的 patch 存在后完全相同）：

1. **先查状态——只读，不写任何东西。**

   跑 `run.cmd` 选 1（只读探针）。它会在脚本
   旁边生成 `stat_<时间戳>.txt`，其中会打印（节选）：

   ```
   --- machine identity (machine.txt seeded automatically from this machine) ---
     BIOS  = '<yours>'  expected '<yours>'  OK
     board = '<yours>'  expected '<yours>'  OK
     model = '<yours>'  expected '<yours>'  OK
   --- TPM-dependent features ---
     BitLocker / device encryption : none protected
   ```

   没给 patch 时不会有"patch 将触碰的记录"一节——仓库里没有内置偏移量
   可供解释。

2. **`machine.txt`——已替你生成。** 文件不存在时，第 1 步会用本机身份
   （注册表里的 `BIOS` / `BOARD` / `MODEL`）自动创建。打开核对三个值即可。
   这就是身份闸门：为一个 BIOS 生成的记录文件，永远别写到另一个上。
   （要在另一台电脑上准备这个目录？改用 `machine.sample.txt` 手工复制——
   写入脚本自己绝不生成这个文件。）

3. **把 H2OUVE 放进 `h2ouve/`**——见 [`h2ouve/README.md`](h2ouve/README.md)。

4. **做 patch。** 跑 `run.cmd` 选 2，指向你固件的 Setup 模块
   （`Setup_FE3542FE-….ffs`，用 UEFITool 抽取——见
   [`tools/README.md`](tools/README.md)），搜索 `Trust Platform Module`。
   它会写出 `patches\trust-platform-module.patch`。打开肉眼核对
   `FROM`/`TO`（`0x02` = 固件 TPM 开 → `0x00` = 禁用）。

5. **应用。** 跑 `run.cmd` 选 4，选中该 patch，键入 `YES`。它会：
   - BitLocker 还在保护任何卷时拒绝运行（退出码 11）；
     BitLocker 状态本身读不到时也拒绝运行（退出码 12）；
   - 身份或布局对不上时拒绝运行；
   - 首次运行时 dump NVRAM 并构建记录文件；
   - 先快照当前值，再写入，再回读验证；
   - 最后提醒你**完全关机**。

6. **确认。** 关机、开机、`run.cmd` 再选 1。fTPM patch 的话字节应变成
   `0x00`，OS 一侧 TPM 应该消失（`Win32_Tpm : no instance`、
   `ACPI\MSFT0101` 设备不在了）。

## 文件一览

```
run.cmd / run.ps1             菜单入口，包裹下面所有引擎

check_status.ps1              只读探针
apply_patch.ps1              写引擎——应用任意 patches\*.patch
restore_original.ps1         回滚引擎——撤销一个 patch
lib/patchfile.ps1            machine.txt 与 *.patch 共用的唯一解析器
ve_parse.py                  解析 H2OUVE -gv dump
mkrec.py                     生成改好的记录文件 / undo 文件
machine.sample.txt           本地（git 忽略的）machine.txt 模板

patches/                     你的 patch 放这里（仓库不带现成的）
tools/ifr_locate.py          找任意设置的 VarStore + 字节偏移（并证明它）
tools/README.md              用法

h2ouve/                      H2OUVE 自备；dump 生成在这里
docs/how-it-works.md         方法详解
docs/making-a-patch.md       patch 格式，以及如何写自己的 patch
```

## 读这个字节的含义

| 字节 | 含义 |
|---|---|
| `0x00` | Disable——fTPM 关 |
| `0x01` | Enable discrete TPM（独立 TPM） |
| `0x02` | Enable firmware TPM——fTPM 开 |

（确切的字节位置是你当前所应用 patch 的 `OFFSET` 键——fTPM 示例是
`0x100`。）

## 回滚

`run.cmd` 选 5（`restore_original.ps1 -Patch <文件>`）会把
`h2ouve/undo_<slug>.txt` 里的原始记录写回去——这是 patch 前 dump 的
逐字节副本，由 `apply_patch.ps1` 在首次写入时生成（`<slug>` 是 patch 文件
名；回滚引擎也接受旧名 `setup_undo.txt`）。因为这个文件**就是**原始字节
的唯一记录，务必保管好：工具从不删除它，但你也不要移动或编辑它。之后
**完全关机**再开机。

## 什么操作会重置这个设置

以下情况固件会重写该变量，fTPM 会回来：

- 刷写 / 更新 BIOS，或清除 CMOS；
- 在 BIOS Setup 里选*载入优化默认值*并保存。

注意，普通的*保存并退出*是无害的——它只会把 `Setup` 变量里已有的内容
原样写回。

## Secure Boot

Secure Boot 是**只报告、不强制**的，这是有意为之。关 fTPM 只动一个与
Secure Boot 无关的 NVRAM 字节；Secure Boot 只影响厂商内核驱动能不能加载。
该驱动的目录文件带微软 WHQL 签名，所以 Secure Boot 开着时写入也完全可能
成功——但这个组合**未经验证**，因此脚本选择警告并继续，而不是拦截。
如果 `segwindrv` 安装失败，去 BIOS 里关掉 Secure Boot 再试。

## 定位你自己的偏移量

仓库不带任何内置偏移量，也不应该带：一个偏移量是某一个固件家族的布局，
换一个 build，同一个数字对应的可能完全是另一回事。从你自己的固件里推导
——别轻信任何人，包括本文件。

`tools/ifr_locate.py` 干这个活：

```
python tools\ifr_locate.py find   Setup.bin "Trust Platform Module"
python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
```

`find` 解码你固件自己的 IFR，打印 `VarStore`、它的 GUID、字节**偏移**、
大小和取值表。`verify` 再按 **GUID** 把这套布局与你的 `-gv` dump 对上，
并检查现场字节确实落在声明的取值表里——偏移量是推导出来并证明过的，
不是假设的。

`find` 还会打印一个候选 **patch 文件**——用 `--out` 可以直接落盘
（`... find Setup.bin "Trust Platform Module" --out patches\my.patch`）。
肉眼核对 `FROM`/`TO` 各是哪个值之后，整套流程（状态检查、应用、回滚）就能
用在你的设置上，与文档里的 fTPM 示例完全一样。完整用法见
[`tools/README.md`](tools/README.md)；手工版见
[`docs/how-it-works.md`](docs/how-it-works.md) §4。

## 故障排查

| 症状 | 可能原因 |
|---|---|
| `ABORT: turn BitLocker OFF`（退出码 11） | 还有卷被 TPM 保护。`manage-bde -off C:`（或 `-protectors -disable C:`），或者你持有恢复密钥时带 `-Force` 重跑。 |
| `unable to confirm that no volume is TPM-protected`（退出码 12） | 两个 BitLocker API 都没响应。自己跑 `manage-bde -status`；如果每个卷都是*保护已关闭*，带 `-Force` 重跑。 |
| 开机直接进**恢复模式** | TPM 消失时 BitLocker 还开着。输入恢复密钥，或跑 `run.cmd` 选 5 把 TPM 找回来，然后 `manage-bde -off C:`。 |
| Windows Hello / PIN 失效 | 预期行为——密钥封在 TPM 里。在登录选项里重新录入。 |
| `GUID format is incorrect` | H2OUVE 要**不带**花括号的 GUID。脚本已经处理好了。 |
| 写入报告成功但没有任何变化 | 最小记录没生效；脚本会自动改用完整 dump 重试。看 `-sv` 输出。 |
| 驱动安装失败 | Secure Boot 开着，或驱动策略被锁。见上文 *Secure Boot*。 |
| `setupapi.dev.log` 里出现设备安装记录 | 预期行为——H2OUVE 每次运行都会装了又卸自己的驱动；脚本会打印日志尾部。 |
| 热重启后字节还是 `0x02` | 彻底断电关机再开机。该设置在上电时才被消费。 |

## 出处与法律

- 方法是在一台 Insyde H2O / AMD 平台上推演出来的；分析脚本
  （`ve_parse.py`、`mkrec.py`、`tools/ifr_locate.py`）为原创。
- `tools/ifr_locate.py` 自行解析 UEFI HII/IFR，不依赖外部工具；也可以
  *可选地*驱动 LongSoft 的 **IFRExtractor-RS**（如果你装了），并且能读懂
  该工具的文本输出以及更老的 **Universal-IFR-Extractor** 排版。两者均不
  随仓库发布、也非必需。
- **H2OUVE 与 segwindrv 是 Insyde Software 的产品**，这里有意不予分发。
  见 [`h2ouve/README.md`](h2ouve/README.md)。
- 代码与文档为 MIT——见 [`LICENSE`](LICENSE)。与 Insyde 或任何整机厂
  无关联。
