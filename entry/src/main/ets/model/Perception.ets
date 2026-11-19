/**
 * 多路感知融合 —— 纯函数模型层
 * 职责：点位几何判定 + 时段选择 + 停留状态机。
 * 与 Knowledge / RoutePlanner / Memory 同级：只做计算，不碰 UI、不碰状态存储。
 */

/** 迟滞带宽（米）。与原先硬编码在 Index.ets 里的 10 保持一致 */
export const HYSTERESIS_M: number = 10;

/** 停留阈值（毫秒） */
export const DWELL_MS: number = 45000;

/** 时段讲解：同一地点在不同时段讲不同侧重。左闭右开 [fromHour, toHour) */
export interface TimeSlot {
  fromHour: number;
  toHour: number;
  knowledgeQuery: string;
  /** 留空 → 回落到 GeoPoint.audioFile */
  audioFile: string;
}

/** GPS 讲解点定义 */
export interface GeoPoint {
  id: string;
  name: string;
  /**
   * 点位标识，与 RoutePlanner.SpotEntry.key 同一套。
   * 用于记忆的 currentSpot 与打卡记录 —— 与 name 分离：
   * name 给人看，spotKey 给代码用（RoutePlanner 自己也是 label/key 分离）。
   * 空串 = 该点位在 RoutePlanner 里暂无对应标识。
   */
  spotKey: string;
  latitude: number;
  longitude: number;
  radius: number;
  /** 点位默认讲解内容（无时段命中时使用） */
  knowledgeQuery: string;
  audioFile: string;
  /** 时段分层配置。为空数组 = 不启用时段，恒用 knowledgeQuery / audioFile */
  slots: TimeSlot[];
}

/** 一次感知判定的结果 */
export interface PerceptDecision {
  inside: boolean;
  /** 在迟滞区内（radius ~ radius+HYSTERESIS_M）—— 保持状态，不触发离开 */
  inHysteresis: boolean;
  /** 本时刻应讲的内容 */
  knowledgeQuery: string;
  audioFile: string;
  /** 命中的时段下标；-1 = 用点位默认 */
  slotIndex: number;
}

/** 停留状态机的状态。整体不可变：每次 tick 返回新对象 */
export interface DwellState {
  /** 当前所在点位 id；'' = 不在任何点位 */
  spotId: string;
  /** 进入时刻 */
  enterAt: number;
  /** 本停留周期是否已推送过（「立即讲解」与「停留提示」共用） */
  pushed: boolean;
}

/** 停留状态机的一次迁移结果 */
export interface DwellEvent {
  next: DwellState;
  /** 本次 tick 是否应推送停留提示 */
  push: boolean;
}

/**
 * 三个点位。id 保持 1/2/3，与旧版一致（打卡与日志里可能已有引用）。
 *
 * ⚠️ 已知几何事实：纪念碑 ↔ 雕塑群 相距 63.4 m，而半径和为 30+40=70 m，
 *    两者有约 6.6 m 的重叠区。重叠区内 checkNearbyPoints 取下标更小者（纪念碑），
 *    而纪念碑 spotKey 为空 → 会清空 currentSpot。这是既有的 fail-closed 设计，不是 bug。
 *    另两组（雕塑群↔子高地 515.7 m、纪念碑↔子高地 ~515 m）无重叠。
 */
export const GEO_POINTS: GeoPoint[] = [
  // ⚠️ 无对应 spotKey：RoutePlanner 的 key 与 label 里都没有「纪念碑」，
  //    它与「纪念馆」不是同一实体，不做无依据的等同。
  {
    id: '1', name: '松山战役纪念碑', spotKey: '',
    latitude: 24.7392, longitude: 98.9058, radius: 30,
    knowledgeQuery: '松山战役纪念碑', audioFile: '',
    slots: [
      { fromHour: 8, toHour: 12, knowledgeQuery: '松山战役', audioFile: '' },
      { fromHour: 12, toHour: 17, knowledgeQuery: '战役地位', audioFile: '' },
      { fromHour: 17, toHour: 19, knowledgeQuery: '总结', audioFile: '' }
    ]
  },
  {
    id: '2', name: '中国远征军雕塑群', spotKey: '雕塑群',
    latitude: 24.7397, longitude: 98.9055, radius: 40,
    knowledgeQuery: '远征军雕塑群', audioFile: 'hero.mp3',
    slots: [
      { fromHour: 8, toHour: 12, knowledgeQuery: '远征军雕塑群', audioFile: '' },
      { fromHour: 12, toHour: 17, knowledgeQuery: '意义', audioFile: '' },
      { fromHour: 17, toHour: 19, knowledgeQuery: '老兵口述', audioFile: '' }
    ]
  },
  {
    id: '3', name: '子高地', spotKey: '子高地',
    latitude: 24.7443, longitude: 98.9061, radius: 30,
    knowledgeQuery: '子高地', audioFile: 'zigaodi.mp3',
    slots: [
      { fromHour: 8, toHour: 12, knowledgeQuery: '子高地', audioFile: '' },
      { fromHour: 12, toHour: 17, knowledgeQuery: '为什么值得铭记', audioFile: '' },
      { fromHour: 17, toHour: 19, knowledgeQuery: '你脚下的土地', audioFile: '' }
    ]
  }
];

/** 球面距离（米）。原 Index.ets.haversineDistance 原样搬移，公式未改 */
export function haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
      Math.sin(dLng / 2) * Math.sin(dLng / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/**
 * 单点位感知判定：几何 + 时段，一步出结果。
 * A2-1（边界）与 A2-2（时空联合）测的都是这个函数，不需要页面。
 *
 * @param now 注入时间。生产传 Date.now()，测试传任意时刻 —— 这是可测性的地基。
 */
export function perceive(point: GeoPoint, lat: number, lng: number, now: number): PerceptDecision {
  const distance: number = haversine(point.latitude, point.longitude, lat, lng);
  const inside: boolean = distance <= point.radius;
  const inHysteresis: boolean = distance > point.radius && distance <= point.radius + HYSTERESIS_M;

  const hour: number = new Date(now).getHours();
  let slotIndex: number = -1;
  for (let i = 0; i < point.slots.length; i++) {
    const slot: TimeSlot = point.slots[i];
    // 左闭右开：8 点整属上午，12 点整属下午，17 点整属傍晚，19 点整起无时段
    if (hour >= slot.fromHour && hour < slot.toHour) {
      slotIndex = i;
      break;
    }
  }

  if (slotIndex < 0) {
    // 无时段命中（含 19:00–次日 07:59）：回落点位默认，向后兼容
    return {
      inside: inside, inHysteresis: inHysteresis,
      knowledgeQuery: point.knowledgeQuery, audioFile: point.audioFile, slotIndex: -1
    };
  }

  const hit: TimeSlot = point.slots[slotIndex];
  return {
    inside: inside, inHysteresis: inHysteresis,
    knowledgeQuery: hit.knowledgeQuery,
    // 时段未配音频 → 回落点位默认；两边都空则无音频（与现状一致，不引入破音）
    audioFile: hit.audioFile !== '' ? hit.audioFile : point.audioFile,
    slotIndex: slotIndex
  };
}

/**
 * 停留状态机。纯函数，可穷举。
 *
 * @param prev        上一 tick 的状态
 * @param pointId     本次判定的点位 id
 * @param inside      是否在半径内
 * @param autoExplain 本次 tick 是否触发了「立即讲解」
 * @param now         判定时刻
 *
 * 与「立即讲解」互斥：本周期内任一者推送过，另一者不再推送。
 * ⚠️ 调用方每个轮询周期【只能调一次】—— 逐点位调用会让未命中点位把 spotId 清空，
 *    下一轮再看命中点位就判成「新进入」，enterAt 被无限重置、阈值永远攒不满。
 */
export function dwellTick(prev: DwellState, pointId: string, inside: boolean,
                          autoExplain: boolean, now: number): DwellEvent {
  // 离开：清空周期
  if (!inside) {
    return { next: { spotId: '', enterAt: 0, pushed: false }, push: false };
  }

  // 进入新点位：开新周期。若这一 tick 同时触发了立即讲解，直接标记已推送
  if (prev.spotId !== pointId) {
    return { next: { spotId: pointId, enterAt: now, pushed: autoExplain }, push: false };
  }

  // 立即讲解触发（补触发的情况）：标记互斥
  if (autoExplain) {
    return { next: { spotId: prev.spotId, enterAt: prev.enterAt, pushed: true }, push: false };
  }

  // 停留够久且本周期未推送 → 推停留提示
  if (!prev.pushed && now - prev.enterAt >= DWELL_MS) {
    return { next: { spotId: prev.spotId, enterAt: prev.enterAt, pushed: true }, push: true };
  }

  return { next: prev, push: false };
}
