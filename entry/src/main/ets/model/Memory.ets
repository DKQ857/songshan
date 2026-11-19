// Memory.ets
//
// 端侧长期记忆（分层记忆的 L2）与记忆调度（L3）。
// L1 短期会话仍由 Index.ets 的 conversationHistory 承担，本文件不碰。
//
// 设计要点：
//   - 存储复用 App 既有的 preferences 库（'xiaozhi_db'），只换 key，
//     不引入数据库 —— 保持架构图底座干净。
//   - currentSpot 也由本类持有并持久化：App 重启后空间分仍可用。
//   - 数量维度（全量/召回）由调用方通过 MemoryQuantity 选择；
//     摆位维度（A/B/C）由 AiService 决定，不在本文件。
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

/** 一条长期记忆：某学生在某点位问过某问题 */
export interface MemoryEntry {
  /** 点位标识，与 RoutePlanner 的 SpotEntry.key 同一套 */
  spot: string;
  question: string;
  /** 回答，截断到 ANSWER_CLIP，防记忆膨胀 */
  answer: string;
  /** 最后一次发生时间（ms） */
  at: number;
  /** 累计问过几次 */
  hits: number;
}

/** 数量维度：FULL = 全量塞（对照组）／ RECALL = 调度召回 top-K（实验组） */
export enum MemoryQuantity { FULL = 0, RECALL = 1 }

/** 摆位维度：A 拼进 user 尾部／B 独立 system message／C 追加进现有 system prompt */
export enum MemoryPlacement { USER_TAIL = 0, SYSTEM_SEPARATE = 1, SYSTEM_APPEND = 2 }

/** 条目上限，超出按 at 淘汰最旧 */
const MEMORY_MAX: number = 200;
/** 召回条数上限 */
const MEMORY_TOP_K: number = 3;
/**
 * 记忆调度的采纳阈值。
 *
 * ⚠️ 2026-09-19 起**不再**与 Knowledge.MATCH_MIN_SCORE 对齐：
 *    后者按 50 条标注 query 实测降到 0.05（它实际控制「本地作答 vs 升级云端」，
 *    不是「回落 T1」—— 低分段 search() 全部返回空）。
 *    本值仍是 0.35 —— A1 的 4 条负例正是靠它挡住误召回，改小会全部崩掉。
 *    两者数值不同是**有意为之**，不是笔误。
 */
const MEMORY_MIN_SCORE: number = 0.35;
/** 单条答案截断长度 */
const ANSWER_CLIP: number = 120;

/** 与 App 主存储共用同一个 preferences 库 */
const PREF_STORE_NAME: string = 'xiaozhi_db';
const PREF_KEY_MEMORY: string = 'user_memory';
const PREF_KEY_CURRENT_SPOT: string = 'current_spot';

/** 三路权重 */
const W_SPATIAL: number = 0.5;
const W_RECENCY: number = 0.2;
const W_RELEVANCE: number = 0.3;

/**
 * 文本相似度：字符 2-gram Jaccard。
 *
 * ⚠️ 刻意不复用 Knowledge 的 diceSimilarity —— 那是 private 实例方法，复用需要把
 * Knowledge 的 normalize / bigrams / diceSimilarity 三层提成模块级导出，会把这处
 * 改动扩散到 Knowledge.ets。为保持本批改动隔离，这里自带一份轻量实现。
 * T2 落地（Knowledge.ets 加 canonicalize）时可一并合并到 utils。
 */
function bigramsOf(text: string): string[] {
  const s: string = text.replace(/[\s，。？！、；：“”‘’《》（）,.?!;:()\-—…]/g, '');
  const out: string[] = [];
  for (let i = 0; i + 1 < s.length; i++) {
    out.push(s.substring(i, i + 2));
  }
  return out;
}

export function jaccard(a: string, b: string): number {
  const ga: string[] = bigramsOf(a);
  const gb: string[] = bigramsOf(b);
  if (ga.length === 0 || gb.length === 0) {
    return 0;
  }
  let inter: number = 0;
  for (let i = 0; i < ga.length; i++) {
    if (gb.indexOf(ga[i]) !== -1) {
      inter++;
    }
  }
  const union: number = ga.length + gb.length - inter;
  return union === 0 ? 0 : inter / union;
}

export default class Memory {
  private entries: MemoryEntry[] = [];
  private store: preferences.Preferences | null = null;
  /** 学生当前点位。持久化 —— App 重启后空间分仍可用 */
  private currentSpot: string = '';
  /** 存储 key。默认生产 key；测试页传 'test_memory' 以隔离真实数据 */
  private prefKey: string;

  constructor(prefKey: string = PREF_KEY_MEMORY) {
    this.prefKey = prefKey;
  }

  private async getStore(context: common.Context): Promise<preferences.Preferences> {
    if (this.store === null) {
      this.store = await preferences.getPreferences(context, PREF_STORE_NAME);
    }
    return this.store;
  }

  /** 启动（或切换账号）时载入一次 */
  async load(context: common.Context): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getStore(context);

      const rawValue: preferences.ValueType = await pref.get(this.prefKey, '[]');
      const rawStr: string = typeof rawValue === 'string' ? rawValue : '[]';
      const parsed: MemoryEntry[] = JSON.parse(rawStr) as MemoryEntry[];
      this.entries = parsed;

      const spotValue: preferences.ValueType = await pref.get(PREF_KEY_CURRENT_SPOT, '');
      this.currentSpot = typeof spotValue === 'string' ? spotValue : '';
    } catch (e) {
      console.error('[Memory] 载入失败，从空开始: ' + (e as Error).message);
      this.entries = [];
      this.currentSpot = '';
    }
  }

  /** 设定当前点位并持久化（值未变则跳过写盘） */
  async setCurrentSpot(context: common.Context, spot: string): Promise<void> {
    if (this.currentSpot === spot) {
      return;
    }
    this.currentSpot = spot;
    try {
      const pref: preferences.Preferences = await this.getStore(context);
      await pref.put(PREF_KEY_CURRENT_SPOT, spot);
      await pref.flush();
    } catch (e) {
      console.error('[Memory] currentSpot 持久化失败: ' + (e as Error).message);
    }
  }

  /** 只读：当前点位 */
  getCurrentSpot(): string {
    return this.currentSpot;
  }

  /** 条目数（调试用） */
  size(): number {
    return this.entries.length;
  }

  /**
   * 落一条记忆。同 (spot, question) 去重累加；超上限按 at 淘汰最旧。
   * 调用方对本地/云端/降级三条链路都应调用 —— 记忆记的是「学生问过什么」。
   */
  async record(context: common.Context, spot: string, question: string, answer: string): Promise<void> {
    if (question.trim() === '') {
      return;
    }
    const now: number = Date.now();
    const clipped: string = answer.length > ANSWER_CLIP ? answer.substring(0, ANSWER_CLIP) : answer;

    let found: boolean = false;
    for (let i = 0; i < this.entries.length; i++) {
      const e: MemoryEntry = this.entries[i];
      if (e.spot === spot && e.question === question) {
        e.answer = clipped;
        e.at = now;
        e.hits = e.hits + 1;
        found = true;
        break;
      }
    }
    if (!found) {
      this.entries.push({ spot: spot, question: question, answer: clipped, at: now, hits: 1 });
    }
    if (this.entries.length > MEMORY_MAX) {
      this.entries.sort((a: MemoryEntry, b: MemoryEntry): number => b.at - a.at);
      this.entries = this.entries.slice(0, MEMORY_MAX);
    }
    await this.persist(context);
  }

  private async persist(context: common.Context): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getStore(context);
      await pref.put(this.prefKey, JSON.stringify(this.entries));
      await pref.flush();
    } catch (e) {
      console.error('[Memory] 持久化失败: ' + (e as Error).message);
    }
  }

  /** 清空全部记忆并落盘。调试与「重置记忆」用 */
  async clearAll(context: common.Context): Promise<void> {
    this.entries = [];
    await this.persist(context);
  }

  /**
   * 三路加权召回。
   *   S_spatial   同点位 1.0 / 路线相邻 0.5 / 其他 0     权重 0.5
   *   S_recency   1 / (1 + Δh/24)                       权重 0.2
   *   S_relevance 字符 2-gram Jaccard(query, 记忆问句)   权重 0.3
   */
  recall(spot: string, adjacentSpots: string[], query: string, now: number): MemoryEntry[] {
    const picked: MemoryEntry[] = [];
    const scores: number[] = [];

    for (let i = 0; i < this.entries.length; i++) {
      const e: MemoryEntry = this.entries[i];

      let sSpatial: number = 0;
      if (spot !== '' && e.spot === spot) {
        sSpatial = 1.0;
      } else if (adjacentSpots.indexOf(e.spot) !== -1) {
        sSpatial = 0.5;
      }

      const dh: number = Math.max(0, now - e.at) / 3600000;
      const sRecency: number = 1 / (1 + dh / 24);
      const sRelevance: number = query === '' ? 0 : jaccard(query, e.question);

      const total: number = W_SPATIAL * sSpatial + W_RECENCY * sRecency + W_RELEVANCE * sRelevance;
      if (total > MEMORY_MIN_SCORE) {
        picked.push(e);
        scores.push(total);
      }
    }

    // 条目量小（≤200），选择排序足够
    for (let i = 0; i < scores.length; i++) {
      for (let j = i + 1; j < scores.length; j++) {
        if (scores[j] > scores[i]) {
          const ts: number = scores[i];
          scores[i] = scores[j];
          scores[j] = ts;
          const te: MemoryEntry = picked[i];
          picked[i] = picked[j];
          picked[j] = te;
        }
      }
    }
    return picked.slice(0, MEMORY_TOP_K);
  }

  /** 全量条目（对照组用） */
  all(): MemoryEntry[] {
    return this.entries.slice();
  }

  /**
   * 拼注入文本。quantity 决定取全量还是 top-K；空结果返回 ''。
   * ⚠️ 返回 '' 时调用方必须跳过注入 —— 不能推空的 system message。
   */
  buildInjection(spot: string, adjacentSpots: string[], query: string,
                 quantity: MemoryQuantity): string {
    const picked: MemoryEntry[] = quantity === MemoryQuantity.FULL
      ? this.all()
      : this.recall(spot, adjacentSpots, query, Date.now());
    if (picked.length === 0) {
      return '';
    }

    const lines: string[] = [];
    for (let i = 0; i < picked.length; i++) {
      const e: MemoryEntry = picked[i];
      lines.push('- 在' + e.spot + '你问过「' + e.question + '」，当时的讲解是：' + e.answer);
    }
    return '【这位学生之前问过的】（' + picked.length + ' 条）\n' + lines.join('\n');
  }
}
