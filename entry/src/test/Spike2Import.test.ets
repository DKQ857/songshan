/**
 * Spike 2 —— 本地单测能否 import main/ets/model 下的纯函数模块。
 *
 * ⚠️ 已得出结论（见下方「判读」段，结论=第一行「import 成功且 perceive() 返回 inside=true」）。
 *    当前【未在 List.test.ets 注册】—— 本文件用 assertEqual('__SHOW_ME__')
 *    故意失败来顶出报告，注册着会让测试套件常驻一个假 ❌，淹没真失败。
 *    需要重验时在 List.test.ets 里加回一行即可。
 *
 * 为什么要验：
 *   计划 Task 2 的 18 条 Hypium 单测要写
 *     import { route } from '../main/ets/model/CapabilityRouter'
 *   但现有测试文件（LocalUnit.test.ets / Ability.test.ets）只 import 过
 *   @ohos/hypium 和 @kit.*，**从没 import 过 main 侧代码** ——
 *   跨根目录的相对路径能否解析、本地单测的运行位置是主机还是设备，都未经验证。
 *
 *   这里用**已存在**的 Perception.ets 来试（纯函数模块、不依赖任何 @ohos.*），
 *   不必等 Task 2 写完 CapabilityRouter 才知道答案。
 *
 * 判读：
 *   - import 成功且 perceive() 返回 inside=true → ✅ 按原计划走 Hypium 单测
 *   - import 失败 / 模块解析不到              → ❌ 立刻改调试页路线，
 *                                                不要等到 Task 2 才撞上
 */
import { describe, it, expect } from '@ohos/hypium';
import { perceive, GEO_POINTS, GeoPoint, PerceptDecision } from '../main/ets/model/Perception';

export default function spike2ImportTest() {
  describe('Spike2_import_main', () => {

    it('能否 import main/ets/model 并调用纯函数', 0, () => {
      let msg: string = '';
      try {
        const p: GeoPoint = GEO_POINTS[0];
        // 取点位正中心 → 必然 inside=true
        const d: PerceptDecision = perceive(p, p.latitude, p.longitude, Date.now());
        msg = 'import 成功；perceive() → inside=' + d.inside
          + ', query=「' + d.knowledgeQuery + '」';
      } catch (e) {
        msg = 'import 或调用失败: ' + JSON.stringify(e);
      }
      console.info('[SPIKE2] ' + msg);

      // ⚠️ 此处【故意】断言失败 —— 目的是让结论直接出现在测试报告里。
      expect(msg).assertEqual('__SHOW_ME__');
    });
  });
}
