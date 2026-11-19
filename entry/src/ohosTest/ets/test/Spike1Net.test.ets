/**
 * Spike 1 —— 探测 @ohos.net.connection 在仿真器上是否真的可用。
 *
 * ⚠️ 已得出结论（见下方「判读」段，结论=第二行「两次结果相同」）。
 *    当前【未在 List.test.ets 注册】—— 本文件用 assertEqual('__SHOW_ME__')
 *    故意失败来顶出报告，注册着会让测试套件常驻一个假 ❌，淹没真失败。
 *    需要重验时（换真机 / 换仿真器版本）在 List.test.ets 里加回一行即可。
 *
 * 为什么必须单独验：
 *   A1 阶段验证过的「断网 → OFFLINE_REPLY」走的是
 *   callAI 请求失败 → catch 的**旧路径**，完全不经过 net.connection。
 *   A3 依赖的是 hasDefaultNetSync / getNetCapabilitiesSync / 变化事件
 *   这条**新路径** —— 与 intelligence 返回 801 是同一个仿真器，
 *   支持与否属于未知，不能假定。
 *
 * 跑法（DevEco 里运行仪器化测试 ohosTest）：
 *   ① 联网状态跑一次，记下输出
 *   ② 模拟器 Disconnect Network 后再跑一次
 *   ③ 对比两次的 hasDefaultNetSync / bearerTypes
 *
 * 判读：
 *   - 联网 True/非空、断网 False/空  → ✅ 新 API 可用，A3 端到端可演示
 *   - 两次结果相同（尤其恒为 True）  → ❌ 仿真器支持旧机制但不支持新 API，
 *                                      snapshot() 会恒返回 STRONG，A3 等于没生效。
 *                                      需要补一层「请求失败反馈」兜底改设计
 *   - 抛 201 → 权限没生效（检查 module.json5）
 *   - 抛 801 → 能力不支持（与 intelligence 同类）
 */
import { describe, it, expect } from '@ohos/hypium';
import connection from '@ohos.net.connection';

export default function spike1NetTest() {
  describe('Spike1_net_connection', () => {

    it('探测 net.connection 同步 API 的真实返回值', 0, () => {
      const lines: string[] = [];

      // ---- 1. hasDefaultNetSync ----
      try {
        const has: boolean = connection.hasDefaultNetSync();
        lines.push('hasDefaultNetSync=' + has);
      } catch (e) {
        lines.push('hasDefaultNetSync@ERR=' + JSON.stringify(e));
      }

      // ---- 2. getDefaultNetSync ----
      try {
        const net: connection.NetHandle = connection.getDefaultNetSync();
        lines.push('getDefaultNetSync.netId=' + net.netId);
      } catch (e) {
        lines.push('getDefaultNetSync@ERR=' + JSON.stringify(e));
      }

      // ---- 3. getNetCapabilitiesSync ----
      try {
        const net: connection.NetHandle = connection.getDefaultNetSync();
        const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
        lines.push('bearerTypes=' + JSON.stringify(caps.bearerTypes));
      } catch (e) {
        lines.push('getNetCapabilitiesSync@ERR=' + JSON.stringify(e));
      }

      // ---- 4. createNetConnection（A3 的事件订阅要用它）----
      try {
        const conn: connection.NetConnection = connection.createNetConnection();
        lines.push('createNetConnection=OK');
      } catch (e) {
        lines.push('createNetConnection@ERR=' + JSON.stringify(e));
      }

      const report: string = lines.join(' | ');
      console.info('[SPIKE1] ' + report);

      // ⚠️ 此处【故意】断言失败 —— 目的是让探测结果直接出现在测试报告里，
      //    免得你去翻 hilog。看到 report 的实际内容 = 探测成功，不是测试挂了。
      expect(report).assertEqual('__SHOW_ME__');
    });
  });
}
