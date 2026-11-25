# MEGAS OTA

MEGAS 系列设备（MEGA S / MEGA 系列 SOC 板）的 **OTA 升级脚本** 与 **升级文件压缩包** 公开分发仓库。

所有升级脚本、升级包及其校验信息集中在此维护，按版本号归档，可直接通过 HTTPS 拉取，无需账号登录。

> 当前状态：仓库已初始化，包含**链路验证假包**与 **MCU A/B 双槽 OTA 测试包**。
> 全部包均为 `fake: true` 的测试产物，**不可用于真实量产升级**。
> **当前可用 MCU 包 = `packages/v9.9.16/`**（实时进度条 + 抗干扰 + 自动回退）。

### 版本矩阵

| 版本 | 大小 | 状态 | 说明 |
|---|---|---|---|
| v9.9.9 | 1732 B | ✅ 链路验证 | 纯假包，验证设备能否从 GitHub 拉包/拉脚本 |
| v9.9.10 | 281190 B | ❌ 作废 | `flash_mcu` 整片擦写路线（ISP 打不通，会冲掉 bootloader） |
| v9.9.11 | 388365 B | ⚠️ 历史 | 首版 A/B 双槽 OTA，未停服务 |
| v9.9.12 | 388803 B | ❌ 作废 | 「停服务」未生效（cat 无权停 root 的 Core） |
| v9.9.13 | 389755 B | ❌ 作废 | 修了 sudo，但 `dd` 撞 root 属主临时目录 |
| v9.9.14 | 390379 B | ⚠️ 历史 | 修好停服务 + PID 隔离目录 + 防中断时的孤儿进程 |
| v9.9.15 | 390824 B | ⚠️ 历史 | OTA 传输中 SIGTERM 可安全恢复，已实测 |
| **v9.9.16** | **608547 B** | ✅ **当前 MCU 包** | + 实时进度条、串口独占守卫、3 次重试、自动回退、双版本镜像 |
| **v9.9.17** | **47625 B** | ✅ **当前系统包** | 系统 tree 覆盖式升级：RNDIS 虚拟网卡环境（脚本 + systemd 单元 + NM 静态档 + PC 上位机） |

> v9.9.16 是 MCU A/B 双槽 OTA（不含任何 RK3568/SOC 镜像）；
> v9.9.17 是系统文件覆盖（zip 内 `etc/` `home/` 即目标绝对路径去掉首个 `/`），
> 两者共用 `Firmware-MegaS-<ver>.zip` 命名，靠版本号区分。
> **v9.9.17 默认 DRY-RUN，不重启系统、不动 ntmega、不切 USB gadget。**

---

## 1. 仓库用途

| 类别 | 说明 |
|---|---|
| 升级脚本 | 设备端 `runUpdate.sh`（拉包、校验、解包、切换、重启、回滚） |
| 升级包 | 实际下发的固件压缩包（`.zip`，内含 `newCore` 与运行时文件） |
| 校验文件 | 每个包对应的同名 `.sha256`，**脚本下载后强制校验** |
| 说明文档 | 版本变更说明、升级注意事项、回滚方法 |

**不存放**：源码、编译中间产物、调试日志、许可证密钥、任何设备私钥。

---

## 2. 目录结构约定

```
megas-ota/
├── README.md
├── scripts/
│   └── runUpdate-github-test.sh   # 链路验证版（固件源指向本仓库，真实升级动作已注释）
├── packages/
│   ├── v9.9.9/                               # 链路验证假包
│   │   ├── Firmware-MegaS-9.9.9.zip
│   │   └── Firmware-MegaS-9.9.9.zip.sha256
│   └── v9.9.16/                              # 当前 MCU 包（解包后为单层目录）
│       ├── Firmware-MegaS-9.9.16.zip
│       └── Firmware-MegaS-9.9.16.zip.sha256
│           # zip 内: MegaTest / megamcu_1.0.0.{4,5}.bin /
│           #        deploy_mcu.sh / lib_ota.sh / ota_once.py / manifest.json / README.txt
├── docs/
│   ├── CHANGELOG.md
│   └── upgrade-guide.md
└── tools/
```

- `scripts/` 与 `packages/` 严格分离：脚本与包分开升级，避免每次只改脚本也要动大包。
- `packages/` 下 **一个版本一个目录**，禁止同目录混放不同版本。
- 单个大文件（> 50 MB）建议走 **Git LFS** 或 Releases 附件，避免仓库膨胀。

---

## 3. 命名规范

### 升级包（与 `runUpdate.sh` 强绑定）

```
packages/v<版本>/Firmware-<版本>.zip            # Mega
packages/v<版本>/Firmware-MegaS-<版本>.zip      # MegaS（megaS 开关）
packages/v<版本>/Firmware-MegaS-<版本>.zip.sha256
```

脚本内部拼的就是这两个名字，**不要改名**：

```bash
ZIP_NAME="Firmware-$VERSION.zip"        # Mega
ZIP_NAME="Firmware-MegaS-$VERSION.zip"  # MegaS
PKG_DIR="packages/v$VERSION"
```

### 版本号

必须 **纯数字点分**（`MAJOR.MINOR.PATCH`）。`runUpdate.sh` 的版本比较用
`((10#$a < 10#$b))`，带 `-beta` 之类的后缀会触发算术错误。

### 标签

每个正式发布打一个 tag：`v1.2.0`（与包内版本号一致）。

---

## 4. 升级包内容要求

```
Firmware-MegaS-<版本>.zip
└── Firmware-MegaS-<版本>/        # 单层目录，脚本会自动识别为载荷根
    ├── newCore                   # 必需，脚本会改名为 Core
    ├── manifest.json
    ├── post-install.sh           # 可选
    └── ...                       # 其余运行时文件（plugins/ 等）
```

脚本的解包逻辑：若解压后顶层「只有一个目录且无其它条目」，就把该目录当载荷根；
否则用解压目录本身。因此**单层目录是推荐形态**。

`manifest.json` 最小字段示例：

```json
{
  "product": "megaS",
  "version": "1.2.0",
  "channel": "stable",
  "min_from_version": "1.0.0",
  "partitions": [
    { "name": "rootfs", "file": "rootfs.ext4.gz", "sha256": "<64 hex>" }
  ],
  "reboot_required": true
}
```

**约束**

- 包内禁止绝对路径、禁止 `..` 越界（解包前脚本需做路径检查）。
- `product` 必须与设备 `8080/discover` 返回的 `productName` 一致，不匹配直接退出。
- 必须支持失败回滚：升级前把 `Core` 备份为 `Core.bak`，失败时切回。
- 升级过程中不得断电；日志保留在 `/tmp/update_tmp/`。

---

## 5. 使用方式

### 5.1 下载

```bash
# 直链（公开仓库无需认证）
curl -fLO https://raw.githubusercontent.com/wenzhihan/megas-ota/main/packages/v9.9.9/Firmware-MegaS-9.9.9.zip
curl -fLO https://raw.githubusercontent.com/wenzhihan/megas-ota/main/packages/v9.9.9/Firmware-MegaS-9.9.9.zip.sha256

git clone --depth 1 https://github.com/wenzhihan/megas-ota.git
```

### 5.2 校验

```bash
sha256sum -c Firmware-MegaS-9.9.9.zip.sha256
```

### 5.3 升级（设备端）

```bash
# MDH 侧会自动 wget 脚本；手动执行等价于：
cd /tmp
wget -O runUpdate.sh https://raw.githubusercontent.com/wenzhihan/megas-ota/main/scripts/runUpdate-github-test.sh
chmod 777 runUpdate.sh
sudo ./runUpdate.sh megaS 9.9.9 1
```

参数：`[dev] [megaS] <version> <choice>`，`choice` 0=null / 1=soc / 2=mcu / 3=soc+mcu。

### 5.4 回滚

```bash
sudo mv -f /home/cat/pub/Core.bak /home/cat/pub/Core && sudo reboot
```

---

## 6. 发布流程

1. 在 `packages/vX.Y.Z/` 下新增 `Firmware-*.zip` 与 `.sha256`；
2. 在 `docs/CHANGELOG.md` 记录变更点、影响范围、注意事项；
3. 提交并打 tag：`git tag -a vX.Y.Z -m "..."` → `git push origin vX.Y.Z`；
4. 在 GitHub 该 tag 上创建 Release；
5. 通知测试 / 产线，附直链与校验值。

---

## 7. 安全与合规

- 本仓库 **公开可读**，任何人可下载；严禁提交私钥、序列号清单、客户信息、内部 IP / 口令。
- 升级包若含敏感配置，请单独维护在私有仓库，仅在此放公开部分。
- 发现包被污染或版本错误，立即在 `docs/CHANGELOG.md` 标注作废 + 重新发布 PATCH 版本。

---

## 8. 支持

- 仓库地址：<https://github.com/wenzhihan/megas-ota>
- 问题反馈：优先在本仓库提 Issue（附设备型号、当前版本、日志片段）

---

## 9. 当前状态

- [x] 仓库创建（public）
- [x] 目录与命名规范定义
- [x] `scripts/runUpdate-github-test.sh`（固件源指向本仓库，**真实升级动作已注释**，DRY-RUN）
- [x] `packages/v9.9.9/Firmware-MegaS-9.9.9.zip`（**虚假测试包**，`manifest.json` 内 `fake: true`）
- [ ] 真实升级包（待提交）
- [ ] `docs/CHANGELOG.md`（待提交）

### 虚假测试包说明

`packages/v9.9.9/` 里的包仅用于验证「设备能否从 GitHub 拉包」，内容为：

| 文件 | 说明 |
|---|---|
| `newCore` | 纯文本占位脚本，**不是可执行固件** |
| `manifest.json` | `fake: true`，`partitions: []` |
| `post-install.sh` | 只打印，不做任何事 |
| `README.txt` | 包内警告说明 |

`scripts/runUpdate-github-test.sh` 里 `kill_old_processes` / 备份覆盖 `/home/cat/pub` /
`chmod` / `./Core -v` / `reboot` 全部注释，只做 下载 → sha256 校验 → 解压 → 载荷体检 → 打印。
**不要在真实设备上用它替换正式 `runUpdate.sh`。**
