# MEGAS OTA

MEGAS 系列设备（MEGA S / MEGA 系列 SOC 板）的 **OTA 升级脚本** 与 **升级文件压缩包** 公开分发仓库。

所有升级脚本、升级包及其校验信息集中在此维护，按版本号归档，可直接通过 HTTPS 拉取，无需账号登录。

> 仓库状态：**已完成初始化，内容待补充**。当前仅含本说明文件，暂未放入任何脚本或升级包。

---

## 1. 仓库用途

| 类别 | 说明 |
|---|---|
| 升级脚本 | 部署到设备端执行的 OTA 流程脚本（拉包、校验、解包、写入、切换分区、重启、回滚） |
| 升级包 | 实际下发的固件 / 根文件系统压缩包（`.tar.gz` / `.zip` / `.img` 等） |
| 校验文件 | 每个包对应的 `.sha256`，用于完整性校验 |
| 说明文档 | 版本变更说明、升级注意事项、回滚方法 |

**不存放**：源码、编译中间产物、调试日志、许可证密钥、任何设备私钥。

---

## 2. 目录结构约定

```
megas-ota/
├── README.md                  # 本文件
├── scripts/                   # 设备端 OTA 脚本
│   ├── ota_upgrade.sh         # 主升级流程
│   ├── ota_rollback.sh        # 回滚
│   └── ota_verify.sh          # 包完整性 / 兼容性校验
├── packages/                  # 升级包，按版本号分目录
│   └── vX.Y.Z/
│       ├── megas-ota-vX.Y.Z.tar.gz
│       └── megas-ota-vX.Y.Z.tar.gz.sha256
├── docs/                      # 版本说明与操作手册
│   ├── CHANGELOG.md
│   └── upgrade-guide.md
└── tools/                     # 可选：打包 / 批量下发辅助脚本
```

- `scripts/` 与 `packages/` 严格分离：脚本与包分开升级，避免每次只改脚本也要动大包。
- `packages/` 下 **一个版本一个目录**，禁止在同目录混放不同版本。
- 单个大文件（> 50 MB）建议走 **Git LFS** 或 Releases 附件，避免仓库膨胀。

---

## 3. 命名规范

### 升级包

```
megas-ota-v<主>.<次>.<修订>[-<硬件型号>][-<通道>].tar.gz
```

示例：

```
megas-ota-v1.2.0-megas.tar.gz          # MEGA S 正式通道
megas-ota-v1.2.0-megas-beta.tar.gz     # MEGA S 测试通道
megas-ota-v1.2.0-mega2io.tar.gz        # LubanCat-2IO 机型
```

### 版本号

遵循语义化版本 `MAJOR.MINOR.PATCH`：

- `MAJOR`：不兼容变更（分区布局、升级协议变更）
- `MINOR`：新增功能，向后兼容
- `PATCH`：缺陷修复，向后兼容

### 标签

每个正式发布打一个 tag：`v1.2.0`（与包内版本号一致）。

---

## 4. 升级包内容要求

一个合规的升级包 **必须** 包含：

```
manifest.json          # 机型、版本、目标分区、依赖版本、sha256
rootfs.ext4.gz         # 或实际镜像文件
post-install.sh        # 可选，安装后钩子（须可重复执行、失败可回滚）
```

`manifest.json` 最小字段示例：

```json
{
  "product": "megas",
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
- 升级脚本必须校验 `manifest.json` 中的 `product` 与设备实际机型一致，不匹配直接退出。
- 必须支持失败回滚：升级前后记录当前槽位 / 分区，失败时切回原分区。
- 升级过程中不得断电；脚本需提示并保留日志到 `/userdata/ota/`。

---

## 5. 使用方式

### 5.1 下载

```bash
# 单个包（直链，公开仓库无需认证）
curl -fLO https://raw.githubusercontent.com/wenzhihan/megas-ota/main/packages/v1.2.0/megas-ota-v1.2.0-megas.tar.gz

# 整仓库（浅克隆）
git clone --depth 1 https://github.com/wenzhihan/megas-ota.git
```

### 5.2 校验

```bash
sha256sum -c megas-ota-v1.2.0-megas.tar.gz.sha256
```

### 5.3 升级（设备端）

```bash
# 建议先停业务进程，避免升级中被占用
systemctl stop ntmega
sh /home/cat/ota/ota_upgrade.sh /home/cat/ota/megas-ota-v1.2.0-megas.tar.gz
```

### 5.4 回滚

```bash
sh /home/cat/ota/ota_rollback.sh
```

> 具体命令以后续提交的脚本为准，本节为约定占位。

---

## 6. 发布流程

1. 在 `packages/vX.Y.Z/` 下新增升级包与 `.sha256`；
2. 在 `docs/CHANGELOG.md` 记录变更点、影响范围、注意事项；
3. 提交并打 tag：`git tag -a vX.Y.Z -m "..."` → `git push origin vX.Y.Z`；
4. 在 GitHub 该 tag 上创建 Release，粘贴 `CHANGELOG` 对应段落；
5. 通知测试 / 产线，附上升级包直链与校验值。

---

## 7. 安全与合规

- 本仓库 **公开可读**，任何人可下载；因此 **严禁** 提交：私钥、证书私钥、设备序列号清单、客户信息、内部 IP / 口令。
- 升级包若含敏感配置，请单独维护在私有仓库，仅在此放公开部分。
- 发现包被污染或版本错误，立即在 `docs/CHANGELOG.md` 标注作废，并删除对应文件 + 重新发布 PATCH 版本。

---

## 8. 支持

- 仓库地址：<https://github.com/wenzhihan/megas-ota>
- 问题反馈：优先在本仓库提 Issue（附设备型号、当前版本、日志片段）

---

## 9. 当前状态

- [x] 仓库创建（public）
- [x] 目录与命名规范定义
- [ ] `scripts/` 升级脚本（待提交）
- [ ] `packages/` 首个升级包（待提交）
- [ ] `docs/CHANGELOG.md`（待提交）
