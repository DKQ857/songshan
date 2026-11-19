/**
 * A3 Task 2 —— CapabilityRouter 决策矩阵单测（本地单测，不需要设备）。
 *
 * 为什么能跑本地单测：CapabilityRouter.ets 是纯函数模块，零 @ohos.* import
 *（见该文件头部的约束）。Spike 2 已验证过这条 import 路径。
 *
 * ⚠️ describe 名必须是纯 ASCII（错误码 00501007，Task 1 实测）；
 *    it 名可含中文（Spike1Net / Spike2Import 已证）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { route, fuseLink, TaskType, RouteTarget, NetTier,
         NetworkState, BatteryState, RuntimeStats, RouteDecision, LinkFeedback }
  from '../main/ets/model/CapabilityRouter';

/** 构造器：减少用例噪声 */
function net(tier: NetTier, bearer: string = 'wifi'): NetworkState {
  return { tier: tier, bearer: bearer };
}
const BAT_OK: BatteryState = { soc: 80, charging: false };
const BAT_LOW: BatteryState = { soc: 10, charging: false };
const BAT_LOW_CHARGING: BatteryState = { soc: 10, charging: true };
const ST_NONE: RuntimeStats = {
  attempts: 0, successes: 0, avgLatencyMs: -1, consecutiveFailures: 0, lastSuccessAt: 0
};
function st(attempts: number, successes: number, avgMs: number): RuntimeStats {
  return { attempts: attempts, successes: successes, avgLatencyMs: avgMs,
           consecutiveFailures: 0, lastSuccessAt: 0 };
}
/** 构造链路反馈，供 A3-5 的 fuseLink 用例使用 */
function fb(fails: number, lastAttemptAt: number, lastSuccessAt: number = 0): LinkFeedback {
  return { consecutiveFailures: fails, lastSuccessAt: lastSuccessAt, lastAttemptAt: lastAttemptAt };
}

/** 固定基准时刻，保证用例可复现 */
const NOW: number = 1758000000000;

export default function a3RouterTest() {

  describe('A3Router_decision_matrix', () => {

    // ===== 网络档位（5 组）=====
    it('A3-1a-01 断网时全部任务走端侧', 0, () => {
      const tasks: TaskType[] = [TaskType.QA_CLOUD, TaskType.PHOTO_RESTORE,
        TaskType.SPEECH_TO_TEXT, TaskType.GRADE_SIMPLIFY, TaskType.TITLE_SUMMARIZE];
      for (let i = 0; i < tasks.length; i++) {
        expect(route(tasks[i], net(NetTier.OFFLINE, 'none'), BAT_OK, ST_NONE).target)
          .assertEqual(RouteTarget.DEVICE);
      }
    });

    it('A3-1a-02 采集失败(UNKNOWN)时全部走云端 —— fail-open', 0, () => {
      const tasks: TaskType[] = [TaskType.QA_CLOUD, TaskType.PHOTO_RESTORE,
        TaskType.SPEECH_TO_TEXT, TaskType.GRADE_SIMPLIFY, TaskType.TITLE_SUMMARIZE];
      for (let i = 0; i < tasks.length; i++) {
        expect(route(tasks[i], net(NetTier.UNKNOWN, ''), BAT_OK, ST_NONE).target)
          .assertEqual(RouteTarget.CLOUD);
      }
    });

    it('A3-1a-03 强网时照片修复走云端，失败回落端侧', 0, () => {
      const d: RouteDecision = route(TaskType.PHOTO_RESTORE, net(NetTier.STRONG), BAT_OK, ST_NONE);
      expect(d.target).assertEqual(RouteTarget.CLOUD);
      expect(d.fallback).assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-04 弱网时照片修复直接走端侧（上传体积大）', 0, () => {
      expect(route(TaskType.PHOTO_RESTORE, net(NetTier.WEAK), BAT_OK, ST_NONE).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-05 UNKNOWN 时照片修复走云端（fail-open 不激进）', 0, () => {
      expect(route(TaskType.PHOTO_RESTORE, net(NetTier.UNKNOWN, ''), BAT_OK, ST_NONE).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    // ===== 语音识别（3 组）=====
    it('A3-1a-06 有网时语音识别走云端（无端侧 ASR）', 0, () => {
      const d: RouteDecision = route(TaskType.SPEECH_TO_TEXT, net(NetTier.STRONG), BAT_OK, ST_NONE);
      expect(d.target).assertEqual(RouteTarget.CLOUD);
      // ⚠️ 语音识别【没有】端侧替代（无端侧 ASR），云端失败后无路可退，
      //    所以 fallback 必须是 CLOUD 而不是 DEVICE —— 填 DEVICE 会指向一个不存在的端侧能力。
      //    对照 A3-1a-03：照片修复有本地增强，那一组才该期望 DEVICE。
      expect(d.fallback).assertEqual(RouteTarget.CLOUD);
    });

    it('A3-1a-07 断网时语音识别走端侧（直接提示用文字）', 0, () => {
      expect(route(TaskType.SPEECH_TO_TEXT, net(NetTier.OFFLINE, 'none'), BAT_OK, ST_NONE).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-08 弱网时语音识别仍走云端（小体积音频）', 0, () => {
      expect(route(TaskType.SPEECH_TO_TEXT, net(NetTier.WEAK), BAT_OK, ST_NONE).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    // ===== 历史成功率（3 组）=====
    it('A3-1a-09 无样本时不受成功率影响', 0, () => {
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, ST_NONE).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    it('A3-1a-10 样本充足且成功率低于阈值 → 降到端侧', 0, () => {
      // 10 次 3 成 = 30% < 阈值 40%
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, st(10, 3, 2000)).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-11 样本不足（<5）时不因成功率降级', 0, () => {
      // 4 次 1 成 = 25%，但样本 < 5，不触发
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, st(4, 1, 2000)).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    // ===== 历史延迟（2 组）=====
    it('A3-1a-12 平均延迟超阈值 → 降到端侧', 0, () => {
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, st(10, 10, 12000)).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-13 平均延迟正常 → 走云端', 0, () => {
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, st(10, 10, 1500)).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    // ===== 电量（3 组）=====
    it('A3-1a-14 低电量且未充电 → 非必要任务降端侧', 0, () => {
      expect(route(TaskType.TITLE_SUMMARIZE, net(NetTier.STRONG), BAT_LOW, ST_NONE).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-15 低电量但充电中 → 不降级', 0, () => {
      expect(route(TaskType.TITLE_SUMMARIZE, net(NetTier.STRONG), BAT_LOW_CHARGING, ST_NONE).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    it('A3-1a-16 电量未知(soc=-1) → 不因电量降级', 0, () => {
      const unknownBat: BatteryState = { soc: -1, charging: false };
      expect(route(TaskType.TITLE_SUMMARIZE, net(NetTier.STRONG), unknownBat, ST_NONE).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    // ===== 优先级：断网压过一切（2 组）=====
    it('A3-1a-17 断网时即便历史成功率满分也走端侧', 0, () => {
      expect(route(TaskType.QA_CLOUD, net(NetTier.OFFLINE, 'none'), BAT_OK, st(100, 100, 500)).target)
        .assertEqual(RouteTarget.DEVICE);
    });

    it('A3-1a-18 决策必带非空 reason（可观测性要求）', 0, () => {
      const d: RouteDecision = route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, ST_NONE);
      expect(d.reason.length > 0).assertTrue();
    });

    // ===== 延迟规则的样本门槛与分任务阈值（2026-09-24 实测踩坑后补）=====
    it('A3-1a-19 样本不足时高延迟不降级（单次测量不足以下结论）', 0, () => {
      // 照片修复第一次成功就可能耗时十几秒。若 1 次样本就能触发规则 5，
      // 后续所有请求会被永久锁死在端侧 —— 因为 DEVICE 分支不调 markAttempt，
      // 统计永不更新，avgLatencyMs 永远停在触发值。
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, st(1, 1, 12000)).target)
        .assertEqual(RouteTarget.CLOUD);
    });

    it('A3-1a-20 照片修复的延迟阈值更宽松（12s 对该功能是正常的）', 0, () => {
      // 同一份 stats：问答判延迟高，照片修复不判 —— 证明阈值是按任务区分的
      const stats: RuntimeStats = st(10, 10, 12000);
      expect(route(TaskType.QA_CLOUD, net(NetTier.STRONG), BAT_OK, stats).target)
        .assertEqual(RouteTarget.DEVICE);
      expect(route(TaskType.PHOTO_RESTORE, net(NetTier.STRONG), BAT_OK, stats).target)
        .assertEqual(RouteTarget.CLOUD);
    });
  });

  // ===== A3-5 反馈层兜底（5 组）=====
  // 仿真器上系统层对断网完全无感（Spike 1），本套用例是唯一能验证断网识别的数据。
  describe('A3Router_link_feedback', () => {

    const SYS_STRONG: NetworkState = { tier: NetTier.STRONG, bearer: 'wifi' };
    const SYS_OFFLINE: NetworkState = { tier: NetTier.OFFLINE, bearer: 'none' };

    it('A3-5-01 连续失败 2 次未达阈值 → 不覆盖', 0, () => {
      const fused: NetworkState = fuseLink(SYS_STRONG, fb(2, NOW - 1000), NOW);
      expect(fused.tier).assertEqual(NetTier.STRONG);
    });

    it('A3-5-02 连续失败 3 次且刚失败过 → 覆盖为 OFFLINE', 0, () => {
      // 核心用例：系统说在线，但实际打不通
      const fused: NetworkState = fuseLink(SYS_STRONG, fb(3, NOW - 1000), NOW);
      expect(fused.tier).assertEqual(NetTier.OFFLINE);
      expect(fused.bearer).assertEqual('fused-offline');
    });

    it('A3-5-03 连续失败 3 次但沉寂 31s → 透传（放探针）', 0, () => {
      const fused: NetworkState = fuseLink(SYS_STRONG, fb(3, NOW - 31000), NOW);
      expect(fused.tier).assertEqual(NetTier.STRONG);
    });

    it('A3-5-04 系统说 OFFLINE → 相信系统（规则1优先于规则2）', 0, () => {
      const fused: NetworkState = fuseLink(SYS_OFFLINE, fb(0, 0), NOW);
      expect(fused.tier).assertEqual(NetTier.OFFLINE);
      expect(fused.bearer).assertEqual('none');
    });

    it('A3-5-05 连续失败清零后 → 融合层解除覆盖', 0, () => {
      // 本组只验融合层的「解覆盖」这一半；
      // 「清零」那一半（markAttempt(ok) 把 consecutiveFailures 归零）
      // 依赖 RouterStats，在 Task 3 的用例里用真实对象验。
      const tripped: NetworkState = fuseLink(SYS_STRONG, fb(3, NOW - 1000), NOW);
      expect(tripped.tier).assertEqual(NetTier.OFFLINE);
      const recovered: NetworkState = fuseLink(SYS_STRONG, fb(0, NOW, NOW), NOW);
      expect(recovered.tier).assertEqual(NetTier.STRONG);
    });
  });
}
