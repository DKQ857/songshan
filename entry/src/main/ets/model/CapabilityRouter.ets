/**
 * 端云协同路由 —— 纯函数决策层。
 *
 * ⚠️ 本文件【不得】import 任何 @ohos.* 系统能力。
 *    网络/电量状态一律作为参数注入 —— 这是可测性的地基，
 *    与 Perception.ets 注入 now 是同一套做法（仿真器上无法精确控制
 *    「切 4G / 断网」，但注入 state 可以穷举）。
 *
 * 本文件在 Task 1 只放【类型 + 常量 + 融合函数】；route() 决策引擎在 Task 2 补。
 */

/** 网络档位。UNKNOWN = 采集失败，决策层按「放行云端」处理（fail-open） */
export enum NetTier {
  OFFLINE = 0,
  WEAK = 1,
  STRONG = 2,
  UNKNOWN = 3
}

export interface NetworkState {
  tier: NetTier;
  /** 'wifi' | 'cellular' | 'other' | 'none' | ''（未知） */
  bearer: string;
}

/** soc: -1 = 未知 */
export interface BatteryState {
  soc: number;
  charging: boolean;
}

/** 某任务类型的近期运行时统计。attempts === 0 表示无样本 */
export interface RuntimeStats {
  attempts: number;
  successes: number;
  /** 平均耗时（毫秒），-1 = 无样本 */
  avgLatencyMs: number;
  /** 该任务**连续**失败次数（任一次成功即清零） */
  consecutiveFailures: number;
  /** 该任务最近一次成功的时间戳；0 = 从未成功 */
  lastSuccessAt: number;
}

// ==================== 链路反馈层 ====================

/**
 * 链路反馈：近期**云端调用**的成败轨迹。
 *
 * ⚠️ 这是【全局】的，不区分任务类型 —— 断网是链路级事实，不是任务级事实。
 *    按任务分开记会导致「某个任务单独连挂 3 次」才触发，反应过慢；
 *    而「照片修复连挂 3 次但问答正常」是服务端问题，不该被当成断网。
 *    （每任务的连续失败次数另记在 RuntimeStats 里，作观测用，不参与融合。）
 */
export interface LinkFeedback {
  /** 连续失败次数（任一次成功即清零） */
  consecutiveFailures: number;
  /** 最近一次成功的时间戳；0 = 从未成功 */
  lastSuccessAt: number;
  /** 最近一次云端调用（无论成败）的时间戳；0 = 从未调用 */
  lastAttemptAt: number;
}

/** 连续失败多少次判定为「实际离线」。**用 `>=`，不要改成 `==`** */
export const FAILURE_STREAK_THRESHOLD: number = 3;

/**
 * 判定离线后，沉寂多久放一次探针请求去探测恢复。
 * ⚠️ **待真机标定**。第二版候补方案：指数退避 30s → 60s → 120s，成功后重置。
 *    第一版先固定 30s。
 */
export const RECOVERY_PROBE_MS: number = 30000;

/**
 * 系统快照 × 链路反馈 → 融合后的网络状态。纯函数，可穷举。
 *
 * 融合规则（优先级从上到下）：
 *   1. 系统说 OFFLINE                          → OFFLINE（相信系统）
 *   2. 连续失败 ≥ 阈值 且 距上次尝试 < 探针间隔  → OFFLINE（**覆盖**系统的 ONLINE）
 *   3. 其余                                     → 原样透传系统读数
 *
 * ⚠️ 规则 2 的「距上次尝试 < 探针间隔」是**必要的兜底**，不是为了省事：
 *    若不设，一旦判定 OFFLINE，route() 会把所有请求拦在端侧 →
 *    永远不再产生云端调用 → consecutiveFailures 永不复位 → **永久卡死在 OFFLINE**。
 *
 * **探针语义**：所谓「放探针」不是让 route() 发什么特殊请求 ——
 * 而是本函数在「连续失败 ≥ 阈值 **且** 沉寂已超 30s」时**不做 OFFLINE 覆盖**，
 * 原样透传系统读数 → route() 正常决策 → 这一次正常请求**就是**探针。
 * 探针失败 → markAttempt 无条件更新 lastAttemptAt → 再等 30s，**不会连发**。
 */
export function fuseLink(sys: NetworkState, fb: LinkFeedback, now: number): NetworkState {
  if (sys.tier === NetTier.OFFLINE) return sys;
  if (fb.consecutiveFailures >= FAILURE_STREAK_THRESHOLD
      && now - fb.lastAttemptAt < RECOVERY_PROBE_MS) {
    return { tier: NetTier.OFFLINE, bearer: 'fused-offline' };
  }
  return sys;
}

// ==================== 决策引擎（Task 2） ====================

/** 云端能力任务类型 */
export enum TaskType {
  QA_CLOUD = 0,
  PHOTO_RESTORE = 1,
  SPEECH_TO_TEXT = 2,
  GRADE_SIMPLIFY = 3,
  TITLE_SUMMARIZE = 4
}

export enum RouteTarget {
  CLOUD = 0,
  DEVICE = 1,
  /** 预留：本期不实现队列执行器 */
  QUEUE = 2
}

export interface RouteDecision {
  target: RouteTarget;
  /** 可读原因，直接进决策日志 */
  reason: string;
  fallback: RouteTarget;
}

/** 成功率低于此值且样本充足 → 降到端侧。⚠️ 待 Task 8 实测标定 */
export const MIN_SUCCESS_RATE: number = 0.4;
/** 样本数门槛：低于此值不因成功率降级 */
export const MIN_SAMPLES: number = 5;
/**
 * 各任务的「平均延迟过高」阈值，下标与 TaskType 一致。
 *
 * ⚠️ 照片修复必须单独放宽：它要上传大图 + 等 GPU + 下载结果，
 *    实测一次成功约 12s；App 侧也明确按「慢卡 60s」设计 readTimeout
 *    （见 BackendService.ts 里不复用 request() 的那段注释）。
 *    用统一的 8s 必然误判 —— 曾导致「第一次修复正常、之后全走端侧」。
 */
export const MAX_AVG_LATENCY_MS: number[] = [
  8000,    // QA_CLOUD
  60000,   // PHOTO_RESTORE  ← 与 readTimeout 量级对齐
  8000,    // SPEECH_TO_TEXT
  8000,    // GRADE_SIMPLIFY
  8000     // TITLE_SUMMARIZE
];
/** 电量低于此值且未充电 → 非必要任务降级。⚠️ 工程惯例值，非实测 */
export const LOW_BATTERY_SOC: number = 15;

/** 不需要云端也能给出可用结果的任务（低电量时优先牺牲它们） */
function isOptional(task: TaskType): boolean {
  return task === TaskType.TITLE_SUMMARIZE
    || task === TaskType.GRADE_SIMPLIFY
    || task === TaskType.QA_CLOUD;
}

/** 该任务在断网时是否有端侧替代 */
function hasDeviceFallback(task: TaskType): boolean {
  return task !== TaskType.SPEECH_TO_TEXT;
}

/**
 * 端云路由决策 —— 纯函数，可穷举。
 *
 * 判定优先级（自上而下，先命中先返回）：
 *   1. 断网          → DEVICE（压过一切，即使历史统计满分）
 *   2. 采集失败      → CLOUD（fail-open，保持改动前行为）
 *   3. 弱网 + 大体积 → DEVICE
 *   4. 历史成功率低  → DEVICE
 *   5. 历史延迟高    → DEVICE
 *   6. 低电量未充电  → 非必要任务 DEVICE
 *   7. 其余          → CLOUD
 */
export function route(task: TaskType, net: NetworkState, battery: BatteryState,
                      stats: RuntimeStats): RouteDecision {
  // 1. 断网：无路可走，直接端侧
  if (net.tier === NetTier.OFFLINE) {
    return {
      target: RouteTarget.DEVICE,
      reason: '断网（bearer=' + net.bearer + '）',
      fallback: RouteTarget.DEVICE
    };
  }

  // 2. 采集失败：fail-open，按现状走云端
  if (net.tier === NetTier.UNKNOWN) {
    return {
      target: RouteTarget.CLOUD,
      reason: '网络状态未知，fail-open 放行云端',
      fallback: hasDeviceFallback(task) ? RouteTarget.DEVICE : RouteTarget.CLOUD
    };
  }

  // 3. 弱网 + 上传体积大的任务：本地增强更快
  if (net.tier === NetTier.WEAK && task === TaskType.PHOTO_RESTORE) {
    return {
      target: RouteTarget.DEVICE,
      reason: '弱网下照片上传体积过大，改用本地增强',
      fallback: RouteTarget.DEVICE
    };
  }

  // 4. 历史成功率低（且样本充足）
  if (stats.attempts >= MIN_SAMPLES
      && stats.successes / stats.attempts < MIN_SUCCESS_RATE) {
    return {
      target: RouteTarget.DEVICE,
      reason: '近期成功率 ' + Math.round(stats.successes * 100 / stats.attempts)
        + '% 低于阈值 ' + Math.round(MIN_SUCCESS_RATE * 100) + '%',
      fallback: RouteTarget.DEVICE
    };
  }

  // 5. 历史延迟高（且样本充足 —— 与规则 4 对称，单次测量不足以下结论）
  //
  // ⚠️ 样本门槛不能去掉：预判 DEVICE 时【不调 markAttempt】，
  //    统计会永久停在触发那一刻 → 规则 5 每次都命中 → 锁死到 App 重启。
  //    门槛保证至少要攒够 MIN_SAMPLES 次真实耗时才有话语权。
  if (stats.attempts >= MIN_SAMPLES
      && stats.avgLatencyMs > MAX_AVG_LATENCY_MS[task]) {
    return {
      target: RouteTarget.DEVICE,
      reason: '近期平均延迟 ' + Math.round(stats.avgLatencyMs)
        + 'ms 超过阈值 ' + MAX_AVG_LATENCY_MS[task] + 'ms',
      fallback: RouteTarget.DEVICE
    };
  }

  // 6. 低电量且未充电：牺牲非必要任务
  if (battery.soc >= 0 && battery.soc < LOW_BATTERY_SOC && !battery.charging
      && isOptional(task)) {
    return {
      target: RouteTarget.DEVICE,
      reason: '电量 ' + battery.soc + '% 且未充电，非必要任务走端侧',
      fallback: RouteTarget.DEVICE
    };
  }

  // 7. 默认走云端
  return {
    target: RouteTarget.CLOUD,
    reason: '网络正常（' + net.bearer + '），走云端',
    fallback: hasDeviceFallback(task) ? RouteTarget.DEVICE : RouteTarget.CLOUD
  };
}
