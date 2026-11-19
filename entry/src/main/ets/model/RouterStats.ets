/**
 * 路由可观测性 —— 决策日志 + 运行时统计。
 *
 * 两个用途：
 *   1. 供 route() 读取历史成功率/延迟（RuntimeStats）
 *   2. 供 A3 测试页输出决策准确率与分布
 *
 * ⚠️ attempts 累计的是【云端调用】的结果，不是决策次数 ——
 *    预判为 DEVICE 而不发起的请求，不计入尝试。
 */
import { TaskType, RouteTarget, NetTier, RuntimeStats, RouteDecision, LinkFeedback }
  from './CapabilityRouter';

export interface DecisionRecord {
  ts: number;
  task: TaskType;
  target: RouteTarget;
  reason: string;
  netTier: NetTier;
  /** 预判 CLOUD 时：是否真的成功；预判 DEVICE 时为 true */
  actualOk: boolean;
  actualMs: number;
}

const TASK_COUNT: number = 5;
const DECISION_LOG_MAX: number = 200;

export class RouterStats {
  private attempts: number[] = [0, 0, 0, 0, 0];
  private successes: number[] = [0, 0, 0, 0, 0];
  private latencySum: number[] = [0, 0, 0, 0, 0];
  /** 每任务连续失败次数（观测用，不参与融合） */
  private taskFailStreak: number[] = [0, 0, 0, 0, 0];
  /** 每任务最近一次成功的时间戳 */
  private taskLastSuccessAt: number[] = [0, 0, 0, 0, 0];
  private log: DecisionRecord[] = [];

  // ===== 全局链路计数器（跨任务，供 fuseLink 使用）=====
  // ⚠️ 必须全局：断网是链路级事实。按任务分会反应过慢，
  //    而且「某任务连挂 3 次但其它任务正常」是服务端问题，不是断网。
  private gFailStreak: number = 0;
  private gLastSuccessAt: number = 0;
  private gLastAttemptAt: number = 0;

  /** 记录一次云端调用的实际结果 */
  markAttempt(t: TaskType, ms: number, ok: boolean): void {
    if (t < 0 || t >= TASK_COUNT) return;
    const now: number = Date.now();

    this.attempts[t]++;
    if (ok) {
      this.successes[t]++;
      this.latencySum[t] += ms;
      this.taskFailStreak[t] = 0;
      this.taskLastSuccessAt[t] = now;
    } else {
      this.taskFailStreak[t]++;
    }

    // 全局：lastAttemptAt 【无条件】更新 —— 这是探针不连发的保证。
    // 若只在失败时更新，成功后的沉寂期就永远不会被重新计时。
    this.gLastAttemptAt = now;
    if (ok) { this.gFailStreak = 0; this.gLastSuccessAt = now; }
    else { this.gFailStreak++; }
  }

  /** 全局链路反馈，供 NetProbe.snapshot(fb, now) 融合 */
  linkFeedback(): LinkFeedback {
    return {
      consecutiveFailures: this.gFailStreak,
      lastSuccessAt: this.gLastSuccessAt,
      lastAttemptAt: this.gLastAttemptAt
    };
  }

  /** 取某任务的统计快照。无样本时 avgLatencyMs = -1 */
  statsOf(t: TaskType): RuntimeStats {
    if (t < 0 || t >= TASK_COUNT) {
      return { attempts: 0, successes: 0, avgLatencyMs: -1,
               consecutiveFailures: 0, lastSuccessAt: 0 };
    }
    const okCnt: number = this.successes[t];
    return {
      attempts: this.attempts[t],
      successes: okCnt,
      avgLatencyMs: okCnt > 0 ? this.latencySum[t] / okCnt : -1,
      consecutiveFailures: this.taskFailStreak[t],
      lastSuccessAt: this.taskLastSuccessAt[t]
    };
  }

  recordDecision(task: TaskType, d: RouteDecision, netTier: NetTier,
                 actualOk: boolean, actualMs: number): void {
    this.log.push({
      ts: Date.now(), task: task, target: d.target, reason: d.reason,
      netTier: netTier, actualOk: actualOk, actualMs: actualMs
    });
    if (this.log.length > DECISION_LOG_MAX) this.log.shift();
  }

  decisions(): DecisionRecord[] { return this.log; }

  /**
   * 决策准确率 = 预判 CLOUD 且成功 / 预判 CLOUD 总数。
   * 预判 DEVICE 的次数不计入分母 —— 我们没有「本来走云端会怎样」的对照，
   * 强行计入会把准确率算成乐观值。
   */
  accuracy(): number {
    let cloud: number = 0;
    let ok: number = 0;
    for (let i = 0; i < this.log.length; i++) {
      if (this.log[i].target !== RouteTarget.CLOUD) continue;
      cloud++;
      if (this.log[i].actualOk) ok++;
    }
    return cloud === 0 ? -1 : ok / cloud;
  }

  summary(): string {
    const lines: string[] = [];
    lines.push('决策总数: ' + this.log.length);
    const acc: number = this.accuracy();
    lines.push('决策准确率: ' + (acc < 0 ? '无云端预判样本' : (acc * 100).toFixed(1) + '%'));
    const names: string[] = ['问答', '照片修复', '语音识别', '学段简化', '标题总结'];
    for (let t = 0; t < TASK_COUNT; t++) {
      const s: RuntimeStats = this.statsOf(t as TaskType);
      if (s.attempts === 0) { lines.push('  ' + names[t] + ': 无样本'); continue; }
      lines.push('  ' + names[t] + ': ' + s.successes + '/' + s.attempts
        + ' 成功, 平均 ' + Math.round(s.avgLatencyMs) + 'ms');
    }
    // 把链路连续失败暴露出来，否则测试页看不到融合层的真实状态
    lines.push('  链路连续失败: ' + this.gFailStreak + ' 次'
      + (this.gLastSuccessAt > 0 ? ', 最近成功于 ' + this.gLastSuccessAt : ''));
    return lines.join('\n');
  }

  /**
   * 清空全部统计。
   * ⚠️ 必须【连链路计数器一起清】—— 只清每任务统计的话，gFailStreak 会残留，
   *    融合层会把 App 继续判成 OFFLINE，表现为「清空按钮按了没用」。
   */
  clear(): void {
    this.attempts = [0, 0, 0, 0, 0];
    this.successes = [0, 0, 0, 0, 0];
    this.latencySum = [0, 0, 0, 0, 0];
    this.taskFailStreak = [0, 0, 0, 0, 0];
    this.taskLastSuccessAt = [0, 0, 0, 0, 0];
    this.gFailStreak = 0;
    this.gLastSuccessAt = 0;
    this.gLastAttemptAt = 0;
    this.log = [];
  }
}
