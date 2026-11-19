# 松山研学 · SongShanAgent

鸿蒙端 AI 红色研学助手。基于 HarmonyOS NEXT（ArkTS / ArkUI）的单模块应用，围绕云南松山战役研学场景，提供**离线知识库问答、多路感知融合、端云协同调度、GPS 自动讲解、AI 出题与报告生成**等能力。应用内助手名为「小智」。

> 本仓库为开源整理版：**不含任何 API Key、签名证书/密码、后端服务代码与竞赛提交材料**。详见文末「开源说明」。

---

## 功能特性

| 模块 | 说明 |
| --- | --- |
| 知识库问答 | 内置离线研学知识库，本地检索命中即答，无需联网；未命中时回落云端大模型 |
| 语音输入 | 麦克风录音 → 语音提问，配合 TTS 播报讲解内容 |
| 照片修复 | 老照片上传后调用云端超分/人脸修复/上色，带进度回调 |
| 路线规划 | 依据研学点位生成游览路线，含点位讲解与里程信息 |
| GPS 自动讲解 | 位置 + 停留时长融合判定，到达讲解点自动触发讲解 |
| AI 出题 | 从题库抽题组卷、缺题提示，支持答案解析 |
| 报告生成 | 汇总本次研学过程，生成可分享的研学报告 |
| 记忆调度 | 本地记忆条目按相关度召回，控制上下文体积 |

## 技术要点

- **端云协同路由**（`entry/src/main/ets/model/CapabilityRouter.ets`）：纯函数决策层，不做任何系统 API 调用，网络/电量/历史成功率等状态一律由外部注入，因此可穷举测试。网络档位 `NetTier = OFFLINE / WEAK / STRONG / UNKNOWN`，采集失败时按「放行云端」的 fail-open 策略处理。
- **多路感知融合**（`model/Perception.ets`）：位置距离 + 停留时长融合出 `PerceptDecision` / `DwellEvent`，`now` 由外部注入，便于在模拟器上做时间仿真。
- **离线优先**：知识库、题库、路线、点位数据打包在应用内（`ets/model/Knowledge.ets`、`utils/QuestionBank.ts`、`model/SchoolData.ets`），断网仍可完成核心讲解流程。
- **可测试性**：决策类模块均为纯函数，配套 `entry/src/test/` 单元测试（Hypium）。

## 目录结构

```
songshan/
├─ AppScope/                       # 应用级配置与图标资源
│  ├─ app.json5                    # bundleName / 版本 / 图标
│  └─ resources/base/...
├─ entry/                          # 唯一业务模块
│  ├─ src/main/
│  │  ├─ module.json5              # 权限、Ability、页面路由、URL scheme
│  │  ├─ ets/
│  │  │  ├─ entryability/          # EntryAbility（应用入口）
│  │  │  ├─ entrybackupability/    # 备份扩展
│  │  │  ├─ pages/                 # SplashPage / Index / LoginPage / RegisterPage / AccountPage
│  │  │  ├─ model/                 # 知识库、路线规划、感知、记忆、端云路由、统计
│  │  │  ├─ service/               # AiService（大模型调用）、NetProbe（网络探测）
│  │  │  └─ utils/                 # 本地账号、用户、头像、TTS、题库、主题、后端接口
│  │  └─ resources/                # 图片、rawfile（内嵌数据/讲解音频）、字符串
│  ├─ src/test/                    # 单元测试
│  └─ src/ohosTest/                # 设备侧集成测试
├─ build-profile.json5             # 构建配置（不含签名信息）
├─ oh-package.json5
├─ code-linter.json5
└─ hvigorfile.ts
```

## 环境要求

- **DevEco Studio 6.1.0** 或更高版本
- HarmonyOS SDK：`compatibleSdkVersion` / `targetSdkVersion` = `6.1.0(23)`
- 设备类型：phone（可在 `entry/src/main/module.json5` 的 `deviceTypes` 中扩展）

## 快速开始

1. 用 DevEco Studio 打开本工程根目录，等待 Sync 完成（会自动安装 `@ohos/hypium`、`@ohos/hamock` 等开发依赖；也可手动执行 `ohpm install`）。
2. **配置大模型 Key**：打开 `entry/src/main/ets/service/AiService.ets`，填入自己的 Key：

   ```ts
   public aiUrl: string = 'https://api.siliconflow.cn/v1/chat/completions';
   public aiKey: string = '';   // ← 填你的 SiliconFlow Key

   private quizUrl: string = 'https://api.deepseek.com/chat/completions';
   private quizKey: string = ''; // ← 填你的 DeepSeek Key（用于 AI 出题）
   ```

   > 也可以用你自己的兼容 OpenAI 协议的网关，替换 `aiUrl` / `quizUrl` 即可。
   > 正式部署建议把 Key 放到服务端代理，客户端不持有第三方密钥。

3. **配置后端地址**（可选，仅「AI 出题 / 账号同步」等需要）：`entry/src/main/ets/utils/BackendService.ts`

   ```ts
   const BASE_URL: string = 'http://127.0.0.1:3000/api/v1';
   ```

   模拟器访问宿主机用 `10.0.2.2`，真机请填局域网 IP 或你的公网地址。

4. **配置签名**：仓库不包含任何签名材料。在 DevEco Studio 的 *Project Structure → Signing Configs* 中勾选自动签名或导入你自己的证书（生成的 `signingConfigs` 请勿提交）。

5. 选择 `entry` 模块 → Run。首次启动会进入 `SplashPage`，随后为登录页；可使用内置演示账号 **`judge` / `demo1234`**（见 `utils/LocalAuth.ts`）直接体验，也可注册新账号。

## 测试

```bash
# 在 DevEco Studio 中：右键 entry/src/test → Run，或用 hvigor 执行测试任务
# 单元测试基于 Hypium，覆盖端云路由、统计、题库解析等纯函数逻辑
```

## 权限与隐私

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.INTERNET` | 云端大模型问答、照片修复 |
| `ohos.permission.MICROPHONE` | 语音输入提问 |
| `ohos.permission.LOCATION` / `APPROXIMATELY_LOCATION` | 到达讲解点判定、GPS 自动讲解 |
| `ohos.permission.GET_NETWORK_INFO` | 判断网络档位，供端云协同路由决策 |

- 对话历史、记忆条目、账号信息仅保存在**本机**（`preferences` / 应用沙箱），不上传第三方服务器。
- 云端请求仅在本地知识库未命中或需要图像修复时发起，且只发送当次问答内容。
- 用户可在应用内删除历史对话与记忆条目。

## 开源说明

本仓库在开源整理时做了以下裁剪：

- **移除**：第三方大模型 API Key、签名证书与密码（`build-profile.json5` 中的 `signingConfigs` 已整体删除）、教师端后端服务代码与数据库、竞赛提交与组委会材料、个人备份目录与 IDE/Agent 配置。
- **保留**：应用源码、资源、构建配置、单元测试与设备侧测试。
- `entry/src/main/resources/rawfile/` 下的点位图片与讲解音频仅用于研学演示；如涉及第三方版权，请联系作者处理。

## 许可

本项目基于 [MIT License](./LICENSE) 开源。
