/**
 * A3 Task 3 —— RouterStats 可观测性单测（本地单测，不需要设备）。
 *
 * ⚠️ describe 名必须纯 ASCII（错误码 00501007）。
 * markAttempt 内部用 Date.now()，本套用例不注入时间 —— 因为断言的都是
 * 「刚调用完」的即时状态，不涉及超时窗口（探针间隔另有 A3-5 用例覆盖）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { RouterStats } from '../main/ets/model/RouterStats';
import { fuseLink, TaskType, RouteTarget, NetTier,
         NetworkState, RouteDecision, RuntimeStats, LinkFeedback }
  from '../main/ets/model/CapabilityRouter';

const SYS_STRONG: NetworkState = { tier: NetTier.STRONG, bearer: 'wifi' };

export default function a3StatsTest() {

  describe('A3Stats_router_stats', () => {

    it('A3-3-01 初始状态：无样本，链路计数全零', 0, () => {
      const s: RouterStats = new RouterStats();
      const st: RuntimeStats = s.statsOf(TaskType.QA_CLOUD);
      expect(st.attempts).assertEqual(0);
      expect(st.avgLatencyMs).assertEqual(-1);
      expect(s.linkFeedback().consecutiveFailures).assertEqual(0);
      expect(s.accuracy()).assertEqual(-1);
    });

    it('A3-3-02 失败一次：attempts 增、successes 不变、连续失败增', 0, () => {
      const s: RouterStats = new RouterStats();
      s.markAttempt(TaskType.QA_CLOUD, 500, false);
      const st: RuntimeStats = s.statsOf(TaskType.QA_CLOUD);
      expect(st.attempts).assertEqual(1);
      expect(st.successes).assertEqual(0);
      expect(st.consecutiveFailures).assertEqual(1);
      expect(s.linkFeedback().consecutiveFailures).assertEqual(1);
    });

    it('A3-3-03 成功一次：连续失败清零、延迟入账、lastSuccessAt 更新', 0, () => {
      const s: RouterStats = new RouterStats();
      s.markAttempt(TaskType.QA_CLOUD, 500, false);
      s.markAttempt(TaskType.QA_CLOUD, 1500, true);
      const st: RuntimeStats = s.statsOf(TaskType.QA_CLOUD);
      expect(st.attempts).assertEqual(2);
      expect(st.successes).assertEqual(1);
      expect(st.consecutiveFailures).assertEqual(0);
      expect(st.avgLatencyMs).assertEqual(1500);
      expect(st.lastSuccessAt > 0).assertTrue();
      expect(s.linkFeedback().consecutiveFailures).assertEqual(0);
    });

    it('A3-3-04 全局计数器【跨任务】累加 —— 证明融合层用全局而非每任务', 0, () => {
      const s: RouterStats = new RouterStats();
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      s.markAttempt(TaskType.PHOTO_RESTORE, 100, false);
      s.markAttempt(TaskType.SPEECH_TO_TEXT, 100, false);
      // 每个任务各自只失败 1 次
      expect(s.statsOf(TaskType.QA_CLOUD).consecutiveFailures).assertEqual(1);
      expect(s.statsOf(TaskType.PHOTO_RESTORE).consecutiveFailures).assertEqual(1);
      // 但全局是 3 —— 正是「断网是链路级事实」的体现
      expect(s.linkFeedback().consecutiveFailures).assertEqual(3);
    });

    it('A3-3-05 recordDecision / decisions / accuracy：预判 DEVICE 不计入分母', 0, () => {
      const s: RouterStats = new RouterStats();
      const dCloud: RouteDecision = {
        target: RouteTarget.CLOUD, reason: 'x', fallback: RouteTarget.DEVICE
      };
      const dDevice: RouteDecision = {
        target: RouteTarget.DEVICE, reason: 'y', fallback: RouteTarget.DEVICE
      };
      s.recordDecision(TaskType.QA_CLOUD, dCloud, NetTier.STRONG, true, 100);
      s.recordDecision(TaskType.QA_CLOUD, dCloud, NetTier.STRONG, false, 100);
      s.recordDecision(TaskType.QA_CLOUD, dDevice, NetTier.OFFLINE, true, 0);
      expect(s.decisions().length).assertEqual(3);
      // 分母只算 2 次 CLOUD 预判，其中 1 次成功
      expect(s.accuracy()).assertEqual(0.5);
    });

    it('A3-3-06 clear() 必须连链路计数器一起清（否则融合层残留 OFFLINE）', 0, () => {
      const s: RouterStats = new RouterStats();
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      expect(s.linkFeedback().consecutiveFailures).assertEqual(3);
      s.clear();
      expect(s.linkFeedback().consecutiveFailures).assertEqual(0);
      expect(s.linkFeedback().lastAttemptAt).assertEqual(0);
      expect(s.statsOf(TaskType.QA_CLOUD).attempts).assertEqual(0);
      expect(s.statsOf(TaskType.QA_CLOUD).consecutiveFailures).assertEqual(0);
      expect(s.decisions().length).assertEqual(0);
    });
  });

  // ===== A3-5-05 的【另一半】：用真实 RouterStats 验「清零 → 恢复」=====
  // Task 2 里只验了融合层的「解覆盖」，这里补上「清零」那一半，
  // 两半合起来才是完整的恢复路径。
  describe('A3Stats_recovery', () => {

    it('A3-5-05b 连续失败触发 OFFLINE → 一次成功后自动恢复 STRONG', 0, () => {
      const s: RouterStats = new RouterStats();

      // ① 3 次失败 → 融合层判 OFFLINE（即使系统说 STRONG）
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      s.markAttempt(TaskType.QA_CLOUD, 100, false);
      const fbTripped: LinkFeedback = s.linkFeedback();
      expect(fbTripped.consecutiveFailures).assertEqual(3);
      expect(fuseLink(SYS_STRONG, fbTripped, Date.now()).tier).assertEqual(NetTier.OFFLINE);

      // ② 探针那次请求成功了 → markAttempt(ok) 清零
      s.markAttempt(TaskType.QA_CLOUD, 200, true);
      const fbRecovered: LinkFeedback = s.linkFeedback();
      expect(fbRecovered.consecutiveFailures).assertEqual(0);

      // ③ 融合层解除覆盖 → 回到系统读数
      expect(fuseLink(SYS_STRONG, fbRecovered, Date.now()).tier).assertEqual(NetTier.STRONG);
    });
  });
}
