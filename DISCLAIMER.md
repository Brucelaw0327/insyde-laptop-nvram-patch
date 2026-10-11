# 免责声明 / Disclaimer

## 中文

**本工具直接修改 UEFI 固件变量（NVRAM）。这不是"改个软件设置"，它动的是固件层。**

1. **可能损坏设备。** 最坏情况下需要拆机清 CMOS，甚至刷新 BIOS 才能恢复。请先确认你有恢复手段。
2. **记录文件与机型/BIOS 版本强绑定。** `setup_new.txt` / `setup_undo.txt` 是按**某一台机器、某一个 BIOS 版本的变量布局逐字节**生成的。写到别的机器上，同一个偏移量可能对应**完全无关的设置**，会静默改坏它。本仓库用 `machine.txt` 身份闸门 + 布局闸门拦这件事，但**闸门不能替代你自己的判断**。
3. **不是刷 BIOS，不改固件镜像。** 只改变量存储（NVRAM），所以 BIOS 版本号不会变。
4. **代价自负。** 作者与贡献者不对任何损坏、数据丢失、保修失效或其他后果负责。见 `LICENSE`（MIT，AS-IS）。
5. **与厂商无关。** 本项目与 Insyde Software、任何 OEM（含小米/OPPO/一加等）均无隶属或背书关系。
6. **H2OUVE 不是本仓库的产物。** 仓库不附带其二进制，也不为其安全性背书 —— 它经由 SMM 与固件通信，被篡改的副本风险极高。请自行从可信来源获取并校验签名。
7. **先关掉 BitLocker 和一切依赖 TPM 的东西。** fTPM 是本机唯一的 TPM；关掉它之后**操作系统再也看不到 TPM**，所有把密钥封在 TPM 里的功能都会失效。
   - **BitLocker / 设备加密：必须先关。** 否则关机再开机时卷会直接进**恢复模式**。用 `manage-bde -off C:` 解密，或 `manage-bde -protectors -disable C:` 只解一次锁。`apply_patch.ps1` 检测到仍受保护会**拒绝执行**（退出码 11）；除非你已持有恢复密钥并加 `-Force` 显式跳过——脚本不替你做这个决定。
   - **Windows Hello（PIN / 指纹 / 人脸）：** 登录密钥封在 TPM 里，之后需要**重新录入**。
   - **Credential Guard / VBS 机密、以及任何把密钥存在 TPM 里的应用：** 那些密钥**不可恢复**。
   - 这些状态用 `run.cmd` 选 1（只读探针）就能看到。
8. **合规。** 本工具面向**你自己的设备**。在你不拥有或未获授权管理的设备上使用，可能违反当地法律或服务条款。

## English

**This tool edits UEFI firmware variables (NVRAM) directly. That is not an
ordinary software setting -- it changes firmware-level state.**

1. **It can brick the machine.** Worst case you need a CMOS clear or a BIOS
   reflash to recover. Make sure you have a recovery path first.
2. **The record files are bound to one machine and one BIOS build.** They are a
   byte-for-byte snapshot of one Setup record; on another build the same offset
   may map to a completely unrelated setting and silently corrupt it. The
   `machine.txt` identity gate and the layout gate exist to stop that, but a
   gate is not a substitute for your own judgement.
3. **This does not flash the BIOS.** Only NVRAM is touched, so the firmware
   version string does not change.
4. **Use at your own risk.** The authors accept no liability for damage, data
   loss, voided warranty, or anything else. See `LICENSE` (MIT, AS-IS).
5. **Not affiliated with any vendor** -- Insyde Software or any OEM.
6. **H2OUVE is not ours and is not distributed here.** It talks to firmware over
   SMM; a tampered copy is a serious risk. Obtain it from a source you trust
   and verify its signature.
7. **Turn off BitLocker and every other TPM-dependent feature first.** The fTPM
   is the only TPM here; once it is off, **the OS sees no TPM at all** and
   anything that seals keys to it stops working.
   - **BitLocker / device encryption: mandatory.** Otherwise the volume boots
     into **recovery mode** at the next power-on. Decrypt with
     `manage-bde -off C:`, or lift the lock for one boot with
     `manage-bde -protectors -disable C:`. `apply_patch.ps1` **refuses to
     run** while a volume is protected (exit code 11) unless you pass `-Force`
     and accept the recovery prompt — the script will not make that call for you.
   - **Windows Hello (PIN / fingerprint / face):** its key is TPM-sealed; you
     will have to **re-enrol** it.
   - **Credential Guard / VBS secrets, and any app that stores a key in the
     TPM:** those keys are **unrecoverable**.
   - `run.cmd` option 1 reports all of the above before you commit.
8. **Legality.** This is for **your own hardware**. Using it on a device you do
   not own or administer may violate local law or terms of service.
