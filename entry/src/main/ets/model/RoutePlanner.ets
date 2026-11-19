export interface RouteStop {
  /** 卡片标题（地点名） */
  name: string;
  /** 站点说明（plan() 里的原文整句） */
  desc: string;
  /** rawfile 下的照片文件名；匹配不到地点时为空串 */
  photo: string;
}

export interface RoutePlan {
  /** 开场白/标题，如「【中学·1小时路线】」；可为空串 */
  intro: string;
  stops: RouteStop[];
}

export interface SpotEntry {
  /** 中文关键词：用于匹配 plan() 正文里的地点，也是打卡记录的存储标识 */
  key: string;
  /** ASCII 别名：二维码和 hdc 调试用，避免中文在命令行/生成工具里出问题 */
  ascii: string;
  label: string;
  photo: string;
  /** 讲解内容的检索词，喂给 Knowledge.search() */
  knowledgeQuery: string;
}

/**
 * 关键词 → 卡片标题 / 照片文件。顺序即匹配优先级
 * （「黄土坡—马鹿塘」取黄土坡，「远征军雕塑群与公墓」取雕塑群）。
 *
 * 以后在 plan() 里加新地点，必须同时往这张表里补一条，
 * 否则新站点会退回「正文前 8 字」当标题、照片留空。
 * 这张表是 SpotEntry 唯一的构造点，加字段时只改这里。
 */
const SPOTS: SpotEntry[] = [
  // knowledgeQuery 前三条沿用 GEO_POINTS 里已经在用的检索词，保持命中率不变
  { key: '纪念馆', ascii: 'museum', label: '松山战役纪念馆', photo: 'spot_museum.jpg', knowledgeQuery: '松山战役纪念碑' },
  { key: '阴登山', ascii: 'yindengshan', label: '阴登山战壕遗址', photo: 'spot_yindengshan.jpg', knowledgeQuery: '阴登山' },
  { key: '子高地', ascii: 'zigaodi', label: '子高地爆破坑', photo: 'spot_zigaodi.jpg', knowledgeQuery: '子高地' },
  { key: '娃娃兵', ascii: 'wawabing', label: '娃娃兵方阵', photo: 'spot_wawabing.jpg', knowledgeQuery: '娃娃兵' },
  { key: '弹痕树', ascii: 'tanhenshu', label: '弹痕树', photo: 'spot_tanhhenshu.jpg', knowledgeQuery: '弹痕树' },
  { key: '雕塑群', ascii: 'sculpture', label: '中国远征军雕塑群', photo: 'spot_sculpture.jpg', knowledgeQuery: '远征军雕塑群' },
  { key: '滚龙坡', ascii: 'gunlongpo', label: '滚龙坡', photo: 'spot_gunlongpo.jpg', knowledgeQuery: '滚龙坡' },
  { key: '大垭口', ascii: 'dayakou', label: '大垭口', photo: 'spot_dayakou.jpg', knowledgeQuery: '大垭口' },
  { key: '红帽坡', ascii: 'hongmaopo', label: '红帽坡梁子', photo: 'spot_hongmaopo.jpg', knowledgeQuery: '红帽坡' },
  { key: '黄土坡', ascii: 'huangtupo', label: '黄土坡', photo: 'spot_huangtupo.jpg', knowledgeQuery: '黄土坡' },
  { key: '马鹿塘', ascii: 'malutang', label: '马鹿塘', photo: 'spot_malutang.jpg', knowledgeQuery: '马鹿塘' },
  { key: '公墓', ascii: 'gongmu', label: '阵亡将士公墓', photo: 'spot_gongmu.jpg', knowledgeQuery: '公墓' },
];

export default class RoutePlanner {
  static plan(grade: string, hours: string): string {
    if (grade === '小学') {
      if (hours === '1h') {
        return '小朋友们，欢迎来到松山！\n' +
          '1. 去看“娃娃兵方阵”——这些战士跟你们差不多大，最小的才9岁，他们非常勇敢。\n' +
          '2. 摸一摸“弹痕树”——树上有很多子弹打的小洞，想象一下当时激烈的战斗。\n' +
          '3. 在公墓前静静地站一会儿，谢谢这些英雄保护了我们的国家。';
      } else if (hours === '2h') {
        return '小朋友，我们要在松山玩两小时啦！\n' +
          '1. 先看“娃娃兵方阵”，听听小英雄张全胜的故事。\n' +
          '2. 去摸“弹痕树”，比一比谁数出的弹孔多。\n' +
          '3. 钻一钻“阴登山战壕”，看看日本鬼子挖的地道和碉堡。\n' +
          '4. 最后到公墓，给烈士叔叔阿姨鞠个躬，说声谢谢。';
      } else {
        return '三小时的松山大冒险！\n' +
          '1. 在纪念馆看大沙盘，就像看地图一样，找到松山在哪里。\n' +
          '2. 看“娃娃兵方阵”，认识9岁的张全胜和14岁的李占宏。\n' +
          '3. 摸“弹痕树”，老师会讲一棵树为什么有这么多伤痕。\n' +
          '4. 走进“阴登山”的地道，感受战士叔叔当时有多困难。\n' +
          '5. 到“子高地”看一个大坑，那是一次秘密的地道大爆炸！\n' +
          '6. 最后献花给英雄，我们永远不会忘记他们。';
      }
    } else if (grade === '中学') {
      if (hours === '1h') {
        return '【中学·1小时路线】\n' +
          '1. 松山战役纪念馆：快速了解1944年的战前态势和双方兵力对比。\n' +
          '2. 阴登山战壕遗址：观察日军机枪掩体结构，分析远征军初期强攻为何伤亡惨重。\n' +
          '3. 子高地爆破坑：重点讲解“坑道爆破”战术——如何用3吨炸药端掉日军核心堡垒。';
      } else if (hours === '2h') {
        return '【中学·2小时路线】\n' +
          '1. 纪念馆：通过沙盘了解滇缅公路的战略意义，以及松山“东方直布罗陀”的地位。\n' +
          '2. 阴登山战壕：实地考察日军三层防御工事，讨论正面仰攻的困境。\n' +
          '3. 子高地爆破坑：拆解坑道爆破的全过程——从挖地道到引爆，理解为什么这是关键转折点。\n' +
          '4. 远征军雕塑群：举行简短的缅怀仪式，思考“为何要铭记历史”。';
      } else {
        return '【中学·3小时路线】\n' +
          '1. 纪念馆：分析日军7个据点群的防御体系，以及远征军“先扫两翼、再攻主峰”的战术思想。\n' +
          '2. 阴登山：还原71军新28师的初次强攻，理解无工事掩护冲锋导致6:1战损比的原因。\n' +
          '3. 滚龙坡：学习“对壕作业”和火焰喷射器拔除子母堡的战术。\n' +
          '4. 大垭口：观察步炮协同的改良——从盲目覆盖到定点摧毁的转变。\n' +
          '5. 子高地爆破坑：复盘坑道爆破的决策、施工与引爆细节。\n' +
          '6. 雕塑群：分组讨论松山战役对抗日战争全局的影响。';
      }
    } else { // 大学
      if (hours === '1h') {
        return '【大学·1小时路线】\n' +
          '1. 纪念馆：深入解析日军松山防御体系——三层钢筋混凝土工事、地下坑道网络与交叉火力配置。\n' +
          '2. 子高地爆破坑：战术拆解——对壕迫近作业、药室选址、TNT装填量与引爆时序，以及爆破后的突入清剿。\n' +
          '3. 红帽坡梁子：探讨兵团轮换攻坚机制，荣3团接替主攻后如何调整攻击波次与兵力部署。';
      } else if (hours === '2h') {
        return '【大学·2小时路线】\n' +
          '1. 纪念馆：战前态势研判——滇西反攻的宏观战略、中美盟军协同及后勤保障体系。\n' +
          '2. 滚龙坡：对壕作业与火焰喷射器的协同战术，分析其对地下工事的毁伤效能。\n' +
          '3. 大垭口：步炮协同的迭代——从饱和炮击到精准火力支援，火炮前置抵近射击的实战案例。\n' +
          '4. 子高地爆破坑：坑道爆破的工程学细节，包括掘进速率、支护结构、药室抗压计算。\n' +
          '5. 黄土坡：残敌清剿阶段的分割包围与逐洞填埋战术，分析日军“玉碎”防御的心理与战术特征。';
      } else {
        return '【大学·3小时路线】\n' +
          '1. 纪念馆：日军松山阵地构造解析——7个据点群、40余子母堡的三维防御体系，以及其火力配系逻辑。\n' +
          '2. 滚龙坡：近迫攻坚战术专题——对壕逼近、火焰喷射器拔堡、壕沟分割孤立敌堡的战术组合。\n' +
          '3. 大垭口：步炮协同的战术演进，从炮兵观测到弹着点修正的全流程分析。\n' +
          '4. 红帽坡梁子：兵团轮换与分区域攻坚的兵力调配，103师、荣1师各部任务衔接与消耗补充。\n' +
          '5. 子高地爆破坑：坑道爆破全链路还原——从地质勘测、药室设计、TNT装填到爆炸效应评估。\n' +
          '6. 黄土坡—马鹿塘：最后清剿阶段的战术调整，填埋、火攻、分割包围的联合运用，以及日军“全员玉碎”的防御心理。\n' +
          '7. 远征军雕塑群与公墓：总结滇缅公路打通后的战略价值，探讨松山战役在二战东方战场中的地位。';
      }
    }
  }

  /** 「1. xxx」→ 去掉行首序号并 trim；不是编号行返回空串 */
  private static stripIndex(line: string): string {
    const t: string = line.trim();
    let i: number = 0;
    while (i < t.length && t.charAt(i) >= '0' && t.charAt(i) <= '9') i++;
    if (i === 0 || i + 1 >= t.length || t.charAt(i) !== '.') return '';
    return t.substring(i + 1).trim();
  }

  /** 正文里第一个命中的地点关键词；都没命中返回 null */
  private static matchSpot(body: string): SpotEntry | null {
    for (let i = 0; i < SPOTS.length; i++) {
      if (body.indexOf(SPOTS[i].key) !== -1) return SPOTS[i];
    }
    return null;
  }

  /**
   * 把 plan() 的文本解析成结构化站点，供全屏路线页渲染。
   * 刻意不重写那 9 张路线表 —— 文案只有 plan() 一份，这里只做解析 + 关键词映射，
   * 于是 plan() 的输出保持字节不变，零回归。
   * 没用正则：ArkTS 里 match() 的 RegExpMatchArray | null 类型很别扭，手写数字扫描更稳。
   */
  static planStops(grade: string, hours: string): RoutePlan {
    const raw: string = RoutePlanner.plan(grade, hours);
    const lines: string[] = raw.split('\n');
    let intro: string = '';
    const stops: RouteStop[] = [];
    for (let i = 0; i < lines.length; i++) {
      const body: string = RoutePlanner.stripIndex(lines[i]);
      if (body === '') {
        // 编号行出现之前的所有非空行，视为开场白/标题
        if (stops.length === 0 && lines[i].trim() !== '') intro = lines[i].trim();
        continue;
      }
      const spot: SpotEntry | null = RoutePlanner.matchSpot(body);
      stops.push({
        name: spot !== null ? spot.label : RoutePlanner.shortTitle(body),
        desc: body,
        photo: spot !== null ? spot.photo : ''
      });
    }
    return { intro: intro, stops: stops };
  }

  /**
   * 未匹配到点位时的标题兜底：截到第一个句读标点为止，找不到标点才退回前 12 字。
   * 原来固定取前 8 字，会把「最后献花给英雄，我们永远不会忘记他们。」
   * 截成「最后献花给英雄，我」—— 截断在半句上。
   */
  private static shortTitle(body: string): string {
    const marks: string[] = ['，', '。', '！', '？', '；'];
    let cut: number = -1;
    for (let i = 0; i < marks.length; i++) {
      const at: number = body.indexOf(marks[i]);
      if (at !== -1 && (cut === -1 || at < cut)) cut = at;
    }
    if (cut === -1) return body.length > 12 ? body.substring(0, 12) : body;
    return body.substring(0, cut);
  }

  /**
   * 按点位标识找地点；找不到返回 null。三级匹配：
   *   ① 中文 key —— 老二维码（之前生成的码用的是「子高地」这类中文）
   *   ② ASCII 别名 —— 新二维码 / hdc 调试（zigaodi 这类）
   *   ③ 全称或子串 —— 兼容 GEO_POINTS 那套「松山战役纪念碑」式全称
   */
  static findSpot(key: string): SpotEntry | null {
    const k: string = key.trim();
    if (k === '') return null;
    for (let i = 0; i < SPOTS.length; i++) {
      if (SPOTS[i].key === k) return SPOTS[i];
    }
    const lower: string = k.toLowerCase();
    for (let i = 0; i < SPOTS.length; i++) {
      if (SPOTS[i].ascii === lower) return SPOTS[i];
    }
    for (let i = 0; i < SPOTS.length; i++) {
      if (SPOTS[i].label === k || k.indexOf(SPOTS[i].key) !== -1) return SPOTS[i];
    }
    return null;
  }

  /** 点位照片文件名；找不到返回空串（渲染时按空串显示占位块） */
  static photoOf(key: string): string {
    const s: SpotEntry | null = RoutePlanner.findSpot(key);
    return s !== null ? s.photo : '';
  }

  /** 点位卡片标题；找不到返回空串 */
  static labelOf(key: string): string {
    const s: SpotEntry | null = RoutePlanner.findSpot(key);
    return s !== null ? s.label : '';
  }

  /** 全部打卡点位，供打卡汇总卡片渲染 */
  static allSpots(): SpotEntry[] { return SPOTS; }
}