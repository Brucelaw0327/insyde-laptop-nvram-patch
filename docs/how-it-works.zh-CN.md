# 工作原理（How it works）

> English: [how-it-works.md](how-it-works.md)

一份方法全解，包括走过的死路——目的是让你能在**自己的**固件上独立复现，而不是信任别人找到的某个字节偏移。

---

## 1. 问题是什么

你想把固件里的 TPM 关掉。很多消费级笔记本的 BIOS Setup 界面要么根本不显示 TPM 页面，要么显示了却没有关闭开关。理论上控制它的设置有：

| 设置项 | IFR 里的典型含义 |
|---|---|
| `Trust Platform Module` | `0 = 禁用`，`1 = 独立 TPM`，`2 = 固件 TPM（fTPM）` |
| `TPM Availability` | `Available` / `Hidden` |
| `Current TPM Device` | 固件当前发布哪个设备 |

它们住在 **`Setup` 这个 UEFI 变量**里（Insyde 的变量存储，GUID 常见为 `A04A27F4-DF00-4D42-B552-39511302113D`）——而这恰好是操作系统**写不进去**的，见下一节。

### 动手之前：谁依赖 TPM

在本文针对的平台上，fTPM 是**唯一的** TPM，所以"fTPM 关闭"等于"操作系统没有 TPM"。这是功能性变更，不只是藏起来一个设置：

- **BitLocker / 设备加密**把卷主key 封在 TPM 里。下次启动时 TPM 没了，卷上没有任何能满足的 protector，会直接进入**恢复模式**——所以 `apply_patch.ps1` 里有硬闸门（退出码 11）。先解密（`manage-bde -off C:`）或挂起一次启动（`manage-bde -protectors -disable C:`）。
- **Windows Hello**（PIN / 指纹 / 人脸）的密钥封在 TPM 里，必须重新登记。
- **Credential Guard / VBS** 的密钥封在 TPM 里且不可恢复；HVCI 失去度量。
- 任何把密钥存进 TPM 的第三方应用都会丢失密钥。

这些都不是固件风险——是**数据**风险——所以它们和固件闸门分开报告。`run.cmd` 选 1 会把全部打出来。

## 2. 走不通的路

从操作系统直接写那个字节是最直观的想法。它失败，而且失败的原因值得搞懂：

**`Setup` 变量是写保护的，而且是按变量*名*逐个锁的。** 直接调 `SetFirmwareEnvironmentVariable` 返回错误 19（`ERROR_WRITE_PROTECT`），EFI Shell 里的 `dmpstore` 也一样。有意思的地方在于：锁是**按名字、不是全局的**。在本方法实际验证过的那台机器上，`Setup` 被锁了，但同门的几个存储（`Custom`、`AmdSetup`、`AMD_PBS_SETUP`、`AOD_SETUP`）可以写。所以"我能不能写变量"是个错误的问题——该问的是"**哪些**能写"。

**TCG2 物理在场路线被规范封死。** TPM2 的 PPI 接口曾经定义过"关闭"操作码；它被删除了。提交 `PPRequest = 2`（DISABLE）的结果是固件消费了请求、判定操作码无效、照常开机。你可以在自己的机器上确认：`Tcg2PhysicalPresence` 变量最终是 `PPRequest = 0`、`LastPPRequest = 2`——即"看到了、拒绝了"。

**标准 AMD CBS/PBS 探测工具翻不到那一页。** 枚举 AMD 超频页面的工具止步于 `AMD CBS` / `AMD PBS`，因为 TPM 选项不在那些 form set 里——它在 OEM 自己的 setup form set 里。只走那些页面的工具会报告"无此选项"，尽管那个字节就在那儿。

**加载共享默认值没用。** 它恢复的是*编译进去*的默认值，而对 OEM 出货版来说通常就是 `固件 TPM`。

## 3. 走得通的路：厂商自己的 SMI 编辑器

Insyde 自带一个控制台工具 **H2OUVE**（`H2OUVE-W-CONSOLEx64.exe`），可以编辑 UEFI 变量。它的价值在于*改写的方式*：

```
H2OUVE-W-CONSOLEx64.exe
   └─ 按需安装/加载 segwindrvx64.sys      （一个有签名的内核驱动）
        └─ 发起一次 Insyde SMI（软中断）
             └─ SMM 处理器  VariableEditSmm   （ring -2）
                  └─ 写 NVRAM 变量存储
```

写操作发生在 **SMM** 里，比存在 `SetVariable` 写保护的 DXE 层还要低——所以挡住操作系统的按名锁管不到它。这不是绕过你拥有的安全边界（固件是你的，你已经是 root 等价权限）；它只是一条厂商自家的合法代码路径。

两条实用备注：

- **H2OUVE 按需自装驱动。** 它创建一个 root 枚举设备、走一遍正常的设备安装（`DIF_INSTALLDEVICE`）、然后再移除。你**不需要**预装任何东西，也不需要 `newdev.dll`。想自己手工架设驱动是个深坑：手工创建的 devnode 没有 HardwareID，`BuildDriverInfoList` 找不到任何东西，安装以 `SPAPI_E_NO_SUCH_DEVINST`（`0xE000020B`）失败。
- **只有 NVRAM 变化。** 没有刷写，固件版本字符串不变，没有刷坏的风险。

## 4. 定位那个字节

不要信 `0x100`。去**证明**它。

### 4.1 用本仓库工具（推荐）

`tools/ifr_locate.py` 一条龙完成，只需要 Python。你提供 **Setup 模块**，其余全部自动推导。

```
# 拿到 Setup 模块本体。在 UEFITool 里找到文本含 "Trust Platform Module"
# 的 PE32 image section，右键 -> Extract body...，存成 Setup.bin。
# （完整 .fd 镜像、或 Setup_<GUID>.ffs 文件也行，只要该模块不在压缩段里。）

python tools\ifr_locate.py scan   Setup.bin
python tools\ifr_locate.py find   Setup.bin "Trust Platform Module"
python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
```

`find` 打印 VarStore、GUID、**VarOffset**、大小、取值表，以及一个可以直接保存的 **patch 文件**存根。`verify` 是关键：它打开你的 `-gv` 转储，**按 GUID**（不按名字）匹配 VarStore，确认该偏移上的实际字节是 IFR 声明的取值之一。在本仓库实际验证过的机器上它输出：

```
IFR VarStore : 'SystemConfig'   guid=A04A27F4-DF00-4D42-B552-39511302113D   size=0x2BC
  record Setup      @105   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x2     -> Enable firmware TPM  (KNOWN value)
  record Custom     @107   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x0     -> Disable  (KNOWN value)
RESULT: consistent -- the IFR layout explains this dump
```

三件事同时成立，而且**没有一件是硬编码的**：固件自己的 IFR 说这个偏移是 TPM 选择器；转储的 GUID 和记录大小与 IFR 声明的 VarStore 吻合；那个字节上的值是 IFR 列出的合法取值。这就是"有人说 `0x100`"和"`0x100` 被证明了"的区别。

**两套引擎。** 默认情况下工具自己遍历 HII FORMS/STRINGS 包，什么都不用下载。如果你已经有 `IFRExtractor-RS`，传 `--ifr-extractor IFRExtractor-RS.exe`，它就改用那个引擎——或者两个都跑然后 diff，结果应当一致。`from-ifr` 解析你之前产出的 IFR 文本文件，支持 IFRExtractor-RS 和更老的 `Universal-IFR-Extractor` 两种排版。

### 4.2 手工做

工具自动化的就是下面这几步；想复核它的 workings 可以手做一遍：

1. **转储变量存储。**
   ```
   h2ouve\H2OUVE-W-CONSOLEx64.exe -gv vars_orig.txt
   ```
   这就是你的回滚源头。留好。

2. **找到选项的定义处。** 解码固件的 setup 模块，定位 prompt 是 TPM 选项的 IFR `ONE_OF` question。它的 `VarStore` id 解析到 `Setup` 存储，question 携带该存储数据内的字节**偏移**。你要的就是这个偏移。（在本仓库实际验证的固件家族上它是 `0x100`。）

3. **按值确认，不是按愿望。** 用 `ve_parse.py` 从转储里读那个字节：
   ```
   python ve_parse.py h2ouve\vars_orig.txt 0x100
   ```
   你应当看到 `Setup` 和 `Custom` 一致，且值对应你当前的 BIOS 设置（示例布局中 `0x02` = 固件 TPM 开）。

4. **构造记录文件。** 通常 `apply_patch.ps1` 会根据 patch 文件代劳。手工做是：
   ```
   python mkrec.py --change 0x100:0x02:0x00
   ```
   产出 `setup_new.txt`（改过的）、`vars_new_full.txt`（完整转储、改过的）和 `setup_undo.txt`（原样备份），并重新解析每个输出、断言目标字节已就位、undo 文件仍保持原样。重复 `--change` 可以一次改多个字节；`--offset / --old / --new` 是单字节写法。

5. **记住你的布局指纹。** `Setup` 记录的 `Attributes` 和 `DataSize`（例如 `0x07` / `0x2BC`）是 BIOS 构建的属性。写盘时*布局闸门*比对的就是这一对，所以记录文件永远写不到一个布局已经变化的构建上。

## 5. 记录文件长什么样

`-gv` 和 `-sv` 用同一种纯文本格式：注释头，然后每个变量一个块——

```
 [069] "Setup"
      GUID: A04A27F4-DF00-4D42-B552-39511302113D
      Attributes: 0x07
      DataSize: 0x2BC
      Data:
            00000000: 66 00 00 00 ...
            00000010: ...
```

`mkrec.py` 逐字节复制这些块，只改写你指定的那几个十六进制 token——其他一切原样，包括换行符。写**最小**文件（只有头 + `Setup` + `Custom`）把影响半径限制在你真正要改的记录上，这正是工具写最小文件而不是整份转储的原因。

两件必须做对的事：

- **GUID 不带花括号。** `-rd -vn "Setup" -vg A04A27F4-...` 可以；带 `{...}` H2OUVE 会回 `GUID format is incorrect`。
- **删除/清零语义。** 按它打印的头说明，把 `DataSize` 或 `Attributes` 置零等于删除变量。本仓库的脚本从不这么干，但手工编辑前值得知道。

## 6. 值得记住的坑

构建本工具时收集的，有些花了真金白银的时间：

**固件里有这个字符串不代表菜单里有这一项。** 固件字符串池是共享的，塞满了没挂载的条目。在这台机器上，setup 模块的字符串表里有 `Load Custom Defaults` 和 `Save Custom Defaults`——但解码所有 form set 后**根本没有 `Exit` form set**，也没有任何东西引用那些字符串。BIOS 的退出页是浏览器画的，真页面只有 `Exit Saving Changes` / `Exit Discarding Changes` / `Load Setup Defaults` / `Discard Changes`。永远用真实截图或 form/IFR 绑定来确认菜单项——绝不要拿 `strings` 命中当证据。

**绝不让生成的脚本携带非 ASCII 路径。** 启动器会写一个小 `.bat` 来调用 H2OUVE 并捕获输出。用 `Encoding.ASCII` 写这个文件、又内插了绝对路径的话，在非英文安装目录下每个重音/CJK 字符都变成 `?`，重定向目标变成打不开的路径，cmd 报"找不到路径"——而 H2OUVE **根本没被启动**，一个静默的空操作。修复：批处理体保持纯 ASCII，路径让 cmd 运行时用 `%~dp0` 展开，路径就永远不由我们编码。

**PowerShell 脚本保持纯 ASCII。** PowerShell 5.1 用控制台代码页解码无 BOM 文件，UTF-8 注释可能被错误解码并带偏解析器。本仓库的 `.ps1` 和 `.cmd` 因此都是纯 ASCII。

**用 diff 验证写入，别信成功消息。** 逐记录比较写前和写后的转储；断言恰好只有一个字节移动了。这就是"工具说 OK"和"固件按我的意图变了"的区别。

## 7. 撤销，以及什么会重新上锁

undo 文件是你第一份转储的逐字节副本，所以恢复它就是把存储原样放回去。因为 fTPM 设置在上电时读取，之后要**彻底断电**——热重启可能不会重读。

以下操作会让固件重写这些变量：

- 刷写/更新 BIOS，或清 CMOS；
- 在 BIOS Setup 里选 *Load Setup Defaults* 并保存。

普通的 *Save and Exit* 是安全的：它把已经在 `Setup` 里的值原样写回。

对一个*已经*卡在恢复模式的卷，救援路径是 `run.cmd` 选项 5（`restore_original.ps1 -Patch <file>`）：把干净的记录写回去，下次启动 protector 又能满足。这也是为什么 restore 脚本只**报告** BitLocker 而不闸它——挡住修复就本末倒置了。（那个卷可能还会要一次恢复密钥；备在手边。）

## 8. 适用范围

本方法适用于任何通过同一 SMI 通道暴露变量存储的 Insyde H2O 平台——包括其他隐藏或写保护的选项（CFG Lock、DVMT、Above 4G decoding 等等）。

**机制是通用的，脚手架也是**：

- `tools/ifr_locate.py` 能为*任何*固件上的*任何*设置找到偏移，并输出 patch 文件。
- patch 文件指名一个存储、它的记录、一个或多个字节改动；偏移不再作为常量出现在任何脚本里。
- `mkrec.py` 能补任何偏移——"打开某项"不过是 `--new` 高于 `--old`，或 `TO` 高于 `FROM`。
- `apply_patch.ps1` / `restore_original.ps1` 是任意 patch 的同一条应用路径和同一条回滚路径，闸门一致。
- §2 和 §6 是真正花时间的地方：哪些路是死的、为什么，哪些陷阱看起来像进展但不是。

fTPM 仍是唯一的完整示例——它的 walkthrough 和 TPM 专属的报告项。仓库不预置任何 patch（预置的就是某一家固件布局披着通用外衣）；你要从自己的固件推导。这个"窄"是故意的：一个你理解的闸门，胜过一个你不理解的框架。所以对整个仓库最诚实的描述是：

**一条验证过的路径，外加一套把风险关进盒子里的方法——fTPM 是它的第一个、也是目前唯一的完整示例。**
