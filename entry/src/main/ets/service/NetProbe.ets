/**
 * 网络状态采集层 —— 系统读数 + 链路反馈，**两层融合**。
 *
 * 设计原则：**fail-open**。仿真器/权限缺失/API 不支持时一律返回 UNKNOWN，
 * 决策层把 UNKNOWN 当作「允许走云端」，即保持改动前的行为。
 * 这样即使采集层完全失效，App 也不会被弄坏。
 *
 * ⚠️ 系统不提供信号强度（ConnectionProperties 里没有 rtt / 带宽），
 *    所以系统层只能区分 OFFLINE / STRONG / UNKNOWN 三态。
 *    真正的 WEAK 由 RuntimeStats 的成功率与延迟在决策层降级判定 ——
 *    两者共用同一套统计数据，不重复采集。
 *
 * ⚠️ 2026-09-20 Spike 1 实测：仿真器上系统层**对断网完全无感**
 *    （断网前后 hasDefaultNetSync 均为 true、netId=101 不变）。
 *    所以反馈层不是锦上添花，它在仿真器上是唯一有效的通路。
 */
import connection from '@ohos.net.connection';
import { NetworkState, NetTier, LinkFeedback, fuseLink } from '../model/CapabilityRouter';

export class NetProbe {
  private listener: connection.NetConnection | null = null;

  /** 纯系统读数，不含反馈层。保留为独立方法，便于单独验证「采集层本身通不通」 */
  private readSystem(): NetworkState {
    try {
      if (!connection.hasDefaultNetSync()) {
        return { tier: NetTier.OFFLINE, bearer: 'none' };
      }
      const net: connection.NetHandle = connection.getDefaultNetSync();
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);

      let bearer: string = 'other';
      const bt: connection.NetBearType[] = caps.bearerTypes;
      if (bt.indexOf(connection.NetBearType.BEARER_WIFI) !== -1) {
        bearer = 'wifi';
      } else if (bt.indexOf(connection.NetBearType.BEARER_CELLULAR) !== -1) {
        bearer = 'cellular';
      }
      return { tier: NetTier.STRONG, bearer: bearer };
    } catch (e) {
      // fail-open：权限缺失、仿真器不支持、系统异常 —— 一律 UNKNOWN
      return { tier: NetTier.UNKNOWN, bearer: '' };
    }
  }

  /**
   * 同步取一次网络快照（系统读数 × 链路反馈）。
   *
   * @param fb  链路反馈，来自 `RouterStats.linkFeedback()`
   * @param now 注入时间 —— 便于测试探针间隔，与 `perceive(point, lat, lng, now)` 同一套做法
   */
  snapshot(fb: LinkFeedback, now: number): NetworkState {
    return fuseLink(this.readSystem(), fb, now);
  }

  /** 订阅网络变化。cb 在每次变化时被调用（调用方自行节流） */
  start(cb: () => void): void {
    try {
      if (this.listener !== null) return;
      this.listener = connection.createNetConnection();
      this.listener.on('netCapabilitiesChange', () => { cb(); });
      this.listener.on('netLost', () => { cb(); });
      this.listener.on('netAvailable', () => { cb(); });
    } catch (e) {
      console.error('[NetProbe] 订阅网络变化失败（fail-open）: ' + (e as Error).message);
      this.listener = null;
    }
  }

  stop(): void {
    try {
      if (this.listener !== null) {
        this.listener.unregister(() => {});
        this.listener = null;
      }
    } catch (e) {
      console.error('[NetProbe] 取消订阅失败: ' + (e as Error).message);
    }
  }
}
