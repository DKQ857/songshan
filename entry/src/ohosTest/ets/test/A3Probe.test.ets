/**
 * A3 Task 1 Step 5 —— 采集层运行时验证。
 *
 * 为什么用仪器化测试而不是往 Index.aboutToAppear() 塞临时代码：
 *   ① 不污染生产文件（Index.ets 一个字符都不用动，也不用加临时 import）
 *   ② 可重复跑，不依赖手点
 *   ③ 权限已在 ohosTest/module.json5 里（GET_NETWORK_INFO），上下文一致
 *
 * ⚠️ 测试框架命名约束（错误码 00501007）：
 *    describe / it 的名称只能含【数字、字母、下划线、句点】，且必须以字母开头。
 *    【不能有中文】。改名前先想一下这一点。
 *
 * ⚠️ 为什么用「中性反馈」探系统层：
 *   readSystem() 是 private，测试不该为了验它而放开封装。
 *   fuseLink 规则 3 是「原样透传」—— 传 consecutiveFailures=0 的中性反馈时，
 *   snapshot() 的返回值【就是】系统读数本身。所以不必碰封装。
 */
import { describe, it, expect } from '@ohos/hypium';
import { NetProbe } from '../../../main/ets/service/NetProbe';
import { NetworkState, NetTier, LinkFeedback } from '../../../main/ets/model/CapabilityRouter';

export default function a3ProbeTest() {
  describe('A3Probe_Task1_NetProbe', () => {

    it('V1_passthrough_V2_override_V3_probe', 0, () => {
      const probe: NetProbe = new NetProbe();
      const now: number = Date.now();

      // ---- V1：中性反馈 → 规则 3 透传 → 等价于直接读系统层 ----
      const neutral: LinkFeedback = { consecutiveFailures: 0, lastSuccessAt: 0, lastAttemptAt: 0 };
      const sys: NetworkState = probe.snapshot(neutral, now);

      // ---- V2：连挂 3 次且刚失败过 → 规则 2 覆盖为 OFFLINE ----
      const tripped: LinkFeedback = {
        consecutiveFailures: 3, lastSuccessAt: 0, lastAttemptAt: now - 1000
      };
      const fused: NetworkState = probe.snapshot(tripped, now);

      // ---- V3：连挂 3 次但沉寂 31s → 规则 2 不成立 → 透传（放探针）----
      const stale: LinkFeedback = {
        consecutiveFailures: 3, lastSuccessAt: 0, lastAttemptAt: now - 31000
      };
      const probed: NetworkState = probe.snapshot(stale, now);

      const tierName: string = sys.tier === NetTier.OFFLINE ? 'OFFLINE'
        : sys.tier === NetTier.WEAK ? 'WEAK'
        : sys.tier === NetTier.STRONG ? 'STRONG' : 'UNKNOWN';
      console.info('[A3-V1] 系统层透传: tier=' + sys.tier + '(' + tierName
        + ') bearer=' + sys.bearer);

      // V1 断言：系统层【能调用且不是 UNKNOWN】。
      // Spike 1 已证本机的 net.connection 可用，所以这里应为 STRONG；
      // 若退化成 UNKNOWN，说明权限没生效或 API 出问题 —— 这是必须立刻知道的事
      //（此时 fail-open 仍保证 App 可用，但 A3 的预判分支会失效）。
      expect(sys.tier === NetTier.UNKNOWN).assertFalse();

      // V2/V3 是【真断言】—— 反馈层是纯逻辑，不依赖仿真器能力，必须成立
      expect(fused.tier).assertEqual(NetTier.OFFLINE);
      expect(fused.bearer).assertEqual('fused-offline');
      expect(probed.tier).assertEqual(sys.tier);
    });
  });
}
