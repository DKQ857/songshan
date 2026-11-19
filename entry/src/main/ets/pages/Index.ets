/**
 * 松山战役智能讲解员 - 首页聊天界面（最终提交版）
 * 包含：知识库问答、语音输入、照片修复、路线规划、报告生成、GPS自动讲解
 * 新增：自动滚动到底部（边生成边翻阅，用户手动滚动停止自动滚动）
 * 新增：历史对话删除功能
 * 新增：当前已是新对话时，点击“新对话”按钮提示而不重复创建
 * 新增：思考中动态旋转加载动画
 * 新增：历史对话框关闭按钮使用 SVG 图标
 */

import Knowledge, { KnowledgeHit, KnowledgeEntry } from '../model/Knowledge';
import promptAction from '@ohos.promptAction';
import media from '@ohos.multimedia.media';
import { BusinessError } from '@ohos.base';
import fs from '@ohos.file.fs';
import RoutePlanner, { RoutePlan, RouteStop, SpotEntry } from '../model/RoutePlanner';
import http from '@ohos.net.http';
import picker from '@ohos.file.picker';
import image from '@ohos.multimedia.image';
import pasteboard from '@ohos.pasteboard';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import buffer from '@ohos.buffer';
import { AiService, AIMessage, RepairProgressCallback, MEMORY_QUANTITY } from '../service/AiService';
import Memory from '../model/Memory';
import { GeoPoint, GEO_POINTS, PerceptDecision, DwellState, DwellEvent, perceive, dwellTick } from '../model/Perception';
import geoLocationManager from '@ohos.geoLocationManager';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import router from '@ohos.router';
import { UserManager } from '../utils/UserManager';
import { BackendService } from '../utils/BackendService';
import { AvatarStore } from '../utils/AvatarStore';
import { TtsSpeaker } from '../utils/TtsSpeaker';
import display from '@ohos.display';
import { BankQuestion, BankShortage, DrawResult, KindWant, drawPaper, parseQuestionBank } from '../utils/QuestionBank';
import { route, TaskType, RouteTarget, NetworkState, NetTier, BatteryState, RouteDecision } from '../model/CapabilityRouter';
import { NetProbe } from '../service/NetProbe';
import { RouterStats } from '../model/RouterStats';
import batteryInfo from '@ohos.batteryInfo';
/** 多模态入口通道。用 enum 不用 type 别名 —— 本项目已验证 export enum 跨文件可用 */
enum EntryChannel { TEXT = 0, VOICE = 1, SCAN = 2 }

// ==================== 常量定义 ====================

const THINKING_QUESTIONS: string[] = [
  '如果你是指挥官，面对子高地的坚固堡垒，你会采用什么战术？',
  '松山战役的胜利对中国抗日战争的全局有什么影响？',
  '我们今天为什么要保护松山战场遗址？'
];

const IGNORED_PATTERNS: string[] = [
  '你好', '我是小智', '讲解员', '欢迎', '嗨！', '大家好', '准备好了吗', '咱们开始吧',
  '很抱歉', '无法提供', '无法回答', '暂时无法', '作为AI', '智能助手', '没有实时', '我不会',
  '抱歉', '我不确定', '让我想想', '根据历史记载', '众所周知', '我们先看看'
];

const PREF_STORE_NAME: string = 'xiaozhi_db';
const PREF_KEY_HISTORY: string = 'chat_history';
const PREF_KEY_SESSIONS: string = 'chat_sessions';
/** 会话序号计数器，用于生成「对话N」。持久化以免删会话后重号 */
const PREF_KEY_SESSION_SEQ: string = 'chat_session_seq';
const PREF_KEY_CHECKINS: string = 'checkin_records';
const PREF_KEY_ROUTE: string = 'route_plan';

/** 已保存的路线：只存参数，路线内容按参数即时重算（planStops 是纯函数） */
interface SavedRoute {
  grade: string;
  hours: string;
}

/** 「生成中」遮罩的最短展示时长。路线/报告都是本地即时生成的，不补下限会毫无过程感 */
const GENERATING_MIN_MS: number = 5000;
/** 提示气泡的展示时长；到点自动收起 */
const ROUTE_HINT_MS: number = 5000;
/** 路线提示气泡只出现一次（装了 App 之后只弹一次，跨启动也不再来） */
const PREF_KEY_ROUTE_HINT: string = 'route_hint_shown';
/** 流式输出：每个 tick 的间隔与整段文字的目标总时长（步长按长度自动算） */
const STREAM_TICK_MS: number = 45;
const STREAM_TOTAL_MS: number = 2600;
/** 路线页流式生成：每张站点卡片浮现的间隔 */
const ROUTE_STOP_REVEAL_MS: number = 320;

// ==================== 出题测试 ====================
// 三个学段各一套规格。题量差异大（30/40/65），固定每题分值凑不出整数 100，
// 所以用「权重制」：每题给原始权重，最后 得分 ÷ 总权重 × 100 折算成百分制。
// 小学那套 4/2 的总权重恰好是 100，折算后与历史成绩完全一致。

/** 一个学段的出题规格 */
interface QuizSpec {
  grade: string;
  singleCount: number;
  multiCount: number;
  judgeCount: number;
  blankCount: number;
  shortCount: number;
  singleWeight: number;
  multiWeight: number;
  judgeWeight: number;
  blankWeight: number;
  shortWeight: number;
}

/** 小学：单选 20 × 4 + 判断 10 × 2 = 总权重 100 */
const QUIZ_SPEC_PRIMARY: QuizSpec = {
  grade: '小学',
  singleCount: 20, multiCount: 0, judgeCount: 10, blankCount: 0, shortCount: 0,
  singleWeight: 4, multiWeight: 0, judgeWeight: 2, blankWeight: 0, shortWeight: 0
};

/** 中学：选择 20（含多选 5）+ 判断 10 + 填空 5 + 简答 5 = 总权重 90 */
const QUIZ_SPEC_MIDDLE: QuizSpec = {
  grade: '中学',
  singleCount: 15, multiCount: 5, judgeCount: 10, blankCount: 5, shortCount: 5,
  singleWeight: 2, multiWeight: 3, judgeWeight: 1, blankWeight: 2, shortWeight: 5
};

/** 大学：选择 30（含多选 10）+ 判断 15 + 填空 10 + 简答 10 = 总权重 115 */
const QUIZ_SPEC_COLLEGE: QuizSpec = {
  grade: '大学',
  singleCount: 20, multiCount: 10, judgeCount: 15, blankCount: 10, shortCount: 10,
  singleWeight: 1, multiWeight: 2, judgeWeight: 1, blankWeight: 2, shortWeight: 4
};

function quizSpecOf(grade: string): QuizSpec {
  if (grade === '小学') return QUIZ_SPEC_PRIMARY;
  if (grade === '中学') return QUIZ_SPEC_MIDDLE;
  return QUIZ_SPEC_COLLEGE;
}

/** 该学段的总题数 */
function specTotalCount(s: QuizSpec): number {
  return s.singleCount + s.multiCount + s.judgeCount + s.blankCount + s.shortCount;
}

/** 该学段的客观题数（不含简答） */
function specObjectiveCount(s: QuizSpec): number {
  return s.singleCount + s.multiCount + s.judgeCount + s.blankCount;
}

/** 该学段的总权重，用于折算百分制 */
function specMaxWeight(s: QuizSpec): number {
  return s.singleCount * s.singleWeight + s.multiCount * s.multiWeight +
    s.judgeCount * s.judgeWeight + s.blankCount * s.blankWeight + s.shortCount * s.shortWeight;
}

/** 某题型的单题权重 */
function specWeightOf(s: QuizSpec, kind: string): number {
  if (kind === 'single') return s.singleWeight;
  if (kind === 'multi') return s.multiWeight;
  if (kind === 'judge') return s.judgeWeight;
  if (kind === 'blank') return s.blankWeight;
  return s.shortWeight;
}

/** 折算后的满分，固定 100 */
const QUIZ_FULL_SCORE: number = 100;
/** 出题解析不合格时的最大重试次数（R1 不支持 JSON mode，格式跑偏是常态） */
const QUIZ_MAX_RETRY: number = 2;
/**
 * 简答题批改失败时的基础得分率。
 * 批改是 AI 调用，断网/格式跑偏都可能失败；此时每题按这个比例给分，
 * 而不是给 0 —— 否则一次服务抖动就把学生整段简答的分抹掉了。
 */
const QUIZ_SHORT_FALLBACK_RATIO: number = 0.6;
/** 测试时长：一个半小时 */
const QUIZ_DURATION_MS: number = 90 * 60 * 1000;
/** 作答中每几次心跳把进度落一次盘（搭在倒计时定时器上，不另开定时器）*/
const QUIZ_AUTOSAVE_TICKS: number = 10;
/** 倒计时进入最后这么多秒时，时间数字转成警示色 */
const QUIZ_WARN_SEC: number = 300;

/** 上次测试的成绩与整份卷子，按用户存本地 —— 退出页面/重开 App 都还在 */
const PREF_KEY_QUIZ: string = 'quiz_last';
/** 进行中的测试（题目+已填答案+截止时间），按用户存本地 —— 关掉测试再开不丢进度 */
const PREF_KEY_QUIZ_PROGRESS: string = 'quiz_progress';
/** 主页面手动选的学段，按用户存本地 —— 否则每次开 App 都重置成「小学」 */
const PREF_KEY_GRADE: string = 'grade_choice';

/**
 * 注册时填的四档学段 → 出题用的三档。
 * 初中和高中共用「中学」卷（中文里「中学」本就含初高中），所以没必要出两套题。
 * 返回空串表示这个学段不认识，调用方不要拿它覆盖已有选择。
 */
function quizSpecGradeOf(level: string): string {
  if (level === '小学') return '小学';
  if (level === '初中' || level === '高中' || level === '中学') return '中学';
  if (level === '大学') return '大学';
  return '';
}

/** 本地保存的上一次测试 */
interface QuizRecord {
  grade: string;
  score: number;
  total: number;
  questions: QuizQuestion[];
  answers: string[];
}

/**
 * 进行中的测试。关掉测试页（或 App 被杀）后重开要能接着答、接着计时，
 * 所以除了题目和已填答案，还得存**绝对截止时间戳** —— 重开时用它算剩余，
 * 而不是重新给一个 90 分钟，否则关掉再开就重置了计时。
 */
interface QuizProgress {
  grade: string;
  questions: QuizQuestion[];
  answers: string[];
  /** 墙上时钟截止时间戳（毫秒）*/
  deadlineMs: number;
}

/** 送去 AI 批改的一道简答 */
interface ShortGradeInput {
  /** 题目在整份卷子里的下标，AI 回传的 index 与它对应 */
  index: number;
  stem: string;
  reference: string;
  mine: string;
}

interface ShortGradeResult {
  /** 与 ShortGradeInput 等长，每题 0-100 的得分率 */
  ratios: number[];
  /** 与 ratios 等长；false = 该题未获 AI 批改，分数是兜底值，不可当作判定结果 */
  gradedItems: boolean[];
  /** false = 走的是兜底基础分，不是 AI 真批的 */
  graded: boolean;
}

/**
 * 从模型正文里抠出 JSON 数组。
 * R1 不支持 response_format: json_object，正文常夹说明文字或 ```json 围栏，
 * 所以定位第一个 '[' 到最后一个 ']' 再解析。
 */
function extractJsonArray(raw: string): Array<Record<string, Object>> {
  const start: number = raw.indexOf('[');
  const end: number = raw.lastIndexOf(']');
  if (start === -1 || end <= start) return [];
  try {
    return JSON.parse(raw.substring(start, end + 1)) as Array<Record<string, Object>>;
  } catch (e) {
    console.error('[QUIZ] JSON 解析失败: ' + (e as Error).message);
    return [];
  }
}

/** 单字母答案是否落在 lo..hi 之间（单选判 A~D 用） */
function isOneLetter(answer: string): boolean {
  return answer.length === 1 && answer >= 'A' && answer <= 'E';
}

/**
 * 把多选答案串排序去重成升序字母，如 'CBA' → 'ABC'。
 * 多选判分做的是集合比较，顺序无关，所以出题和作答两侧都要先归一到这个形态。
 */
function sortLetters(s: string): string {
  const chars: string[] = [];
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c >= 'A' && c <= 'E' && chars.indexOf(c) === -1) chars.push(c);
  }
  chars.sort();
  return chars.join('');
}

/**
 * 填空判分的归一化：去掉空白与常见中英文标点，只留实义字符。
 * 「1944 年」与「1944年」、「松山，」与「松山」视为同一答案。
 */
function normalizeBlank(s: string): string {
  return s.replace(/[\s，。、；：！？,.!?;:""''（）()《》【】「」]/g, '');
}

/** 一道题。五种 kind：single 单选 / multi 多选 / judge 判断 / blank 填空 / short 简答 */
interface QuizQuestion {
  kind: string;
  stem: string;
  /** 单选 4 个选项、多选 4-5 个选项、判断与填空简答为空数组 */
  options: string[];
  /**
   * single：'A'~'D'
   * multi ：按字母升序拼成的串，如 'ABC'（判分时做集合相等比较，顺序无关）
   * judge ：'T' / 'F'
   * blank ：参考答案
   * short ：参考答案要点（供 AI 批改时对照）
   */
  answer: string;
  /** 仅填空用：可接受的其它写法，本地判分时逐个比 */
  accept: string[];
  explain: string;
}

/** 多选勾选/取消：在升序字母串里加上或去掉一个字母 */
function toggleLetter(current: string, letter: string): string {
  if (current.indexOf(letter) === -1) return sortLetters(current + letter);
  return sortLetters(current.replace(letter, ''));
}

/** 逐题明细，存进后端供教师端查看 */
interface QuizDetailRow {
  index: number;
  kind: string;
  stem: string;
  mine: string;
  answer: string;
  ok: boolean;
  /** 简答题的 AI 得分率 0-100；客观题恒为 100 或 0 */
  ratio: number;
}

/** 排行榜一行（对应后端 /app/quiz/ranking 的 list 元素） */
interface QuizRankItem {
  rank: number;
  userId: number;
  name: string;
  className: string;
  score: number;
  total: number;
}

function readStr(obj: Record<string, Object>, key: string): string {
  const v: Object = obj[key];
  if (v === undefined || v === null) return '';
  return String(v);
}

function readNum(obj: Record<string, Object>, key: string): number {
  const v: Object = obj[key];
  if (v === undefined || v === null) return 0;
  return Number(v);
}

function toRankItem(r: Record<string, Object>): QuizRankItem {
  return {
    rank: readNum(r, 'rank'),
    userId: readNum(r, 'user_id'),
    name: readStr(r, 'name'),
    className: readStr(r, 'class_name'),
    score: readNum(r, 'score'),
    total: readNum(r, 'total')
  };
}

/** 解析 /app/quiz/ranking 的 list。字段都是后端 snake_case，逐项读出避免整体强转 */
function parseQuizRanking(raw: Record<string, Object>): QuizRankItem[] {
  const listRaw = raw['list'] as Array<Record<string, Object>>;
  const out: QuizRankItem[] = [];
  if (listRaw === undefined || listRaw === null) return out;
  for (let i = 0; i < listRaw.length; i++) out.push(toRankItem(listRaw[i]));
  return out;
}

/** 解析 /app/quiz/ranking 的 me（当前学生自己那行）；没有则返回 null */
function parseQuizMe(raw: Record<string, Object>): QuizRankItem | null {
  const meRaw = raw['me'];
  if (meRaw === undefined || meRaw === null) return null;
  return toRankItem(meRaw as Record<string, Object>);
}

/**
 * 打卡记录。userId 用 UserInfo.id 做归属，游客为 0。
 * source 沿用 ScanResult.source 的语义：'camera' = 系统相机扫的，'photo' = 相册扫的，
 * 教师视图按它区分真扫还是相册扫。
 */
interface CheckinRecord {
  spotKey: string;
  timestamp: number;
  userId: number;
  source: string;
}

/**
 * 从 deep link 里抽 point 参数。没有 query 串就返回原串
 * （相册扫出的内容可能直接就是点位标识本身）。
 * 解析规则与 EntryAbility.handleDeepLink 保持一致。
 */
export function extractPointParam(raw: string): string {
  const qi: number = raw.indexOf('?');
  if (qi === -1) return raw.trim();
  const pairs: string[] = raw.substring(qi + 1).split('&');
  for (let i = 0; i < pairs.length; i++) {
    const kv: string[] = pairs[i].split('=');
    if (kv.length === 2 && kv[0] === 'point') return decodeURIComponent(kv[1]);
  }
  return '';
}

// ==================== 多问题连发拆分常量 ====================
/** 疑问词。必须按长度降序，保证「为什么」不被「什么」重复计数 */
const QUESTION_MARKERS: string[] = [
  '为什么', '什么', '哪个', '哪里', '哪儿', '怎么', '多少', '多久', '谁', '几'
];
/** 高优先级切点：第一句的自然收尾字 */
const SPLIT_ANCHORS_HIGH: string[] = ['的', '了', '吗', '呢', '吧', '？', '?', '。', '！', '!'];
/** 低优先级切点：句间分隔标点，仅在高优先级切点不存在时使用 */
const SPLIT_ANCHORS_LOW: string[] = ['，', ',', '；', ';', '、'];
/** 最多拆分出的子问题数量 */
const MAX_SUB_QUESTIONS: number = 3;
/** 拆句失败时的提示语 */
const MULTI_QUESTION_HINT: string = '\n\n你好像问了不止一个问题，先回答第一个，其他的可以继续问我。';

/** 路径1 话术：真断网/超时。是环境问题、可恢复，所以给出「联网后再试」的指引 */
const OFFLINE_REPLY: string = '我现在没有联网，只能回答松山战役和松山遗址的问题。你可以先问我战役背景、关键战斗、英雄人物或遗址景点，联网后再试也行。';
/** 路径2 话术：云端答了但越界或史实错误被拦截。此时网络是好的，不能说"没联网"，只说答不了 */
const OUT_OF_SCOPE_REPLY: string = '这个问题我没法给出准确的答案。我只讲松山战役和松山遗址里、有据可查的内容——比如战役背景、关键战斗、英雄人物和遗址景点。你可以换个角度问我。';

// ==================== 数据接口 ====================

interface SessionData {
  id: number;
  title: string;
  messages: ChatMessageData[];
  history: AIMessage[];
  timestamp: number;
  /** 置顶标记。历史数据没有该字段，读取时用 `s.isPinned ? 1 : 0` 兜底 */
  isPinned: boolean;
  /** 标题来源：true = 用户手动改过，自动总结不再覆盖。历史数据没有该字段，按 falsy 兜底 */
  isCustomTitle: boolean;
}

interface ChatMessageData {
  id: number;
  type: number;
  text: string;
  audioFile: string;
  isKnowledge: boolean;
  /** 卡片类型：'' = 普通；'spot' = 扫码点位讲解；'checkinList' = 打卡汇总 */
  cardType: string;
  /** 点位标识，cardType === 'spot' 时有效 */
  spotKey: string;
  /** 打卡来源：'camera' / 'photo'；非点位卡片为空串 */
  spotSource: string;
}

interface AIAudioData { data: string; format: string; }
interface AIContentPart { type: string; text?: string; audio?: AIAudioData; }
interface AIChatMessage { role: string; content: string | AIContentPart[]; }
interface AIRequestBody { model: string; messages: AIChatMessage[]; max_tokens?: number; temperature?: number; }
interface AIResponseChoiceMessage { content: string; }
interface AIResponseChoice { message: AIResponseChoiceMessage; }
interface AIResponseBody { choices: AIResponseChoice[]; }

// GPS讲解点定义已移至 model/Perception.ets（含 slots 时段分层）

const WAVE_BARS: number[] = [1, 2, 3, 4, 5, 6, 7];

// ==================== 消息模型 ====================

@Observed
class ChatMessage {
  id: number;
  type: number;
  text: string;
  audioFile: string;
  imagePixelMap: image.PixelMap | null = null;
  isKnowledge: boolean = false;
  isThinking: boolean = false;
  repairProgress: number = -1;
  /** 「猜你想问」候选问题；不持久化，仅当前会话可见 */
  suggestions: string[] = [];
  /** 卡片类型：'' = 普通；'spot' = 扫码点位讲解；'checkinList' = 打卡汇总 */
  cardType: string = '';
  /** 点位标识，cardType === 'spot' 时有效 */
  spotKey: string = '';
  /** 打卡来源：'camera'（系统相机扫的）/ 'photo'（相册扫的） */
  spotSource: string = '';

  constructor(id: number, type: number, text: string, audioFile: string = '') {
    this.id = id;
    this.type = type;
    this.text = text;
    this.audioFile = audioFile;
  }
}

// ==================== 主组件 ====================

@Entry
@Component
struct Index {
  @State @Watch('onMessagesChanged') messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State voiceEnabled: boolean = true;
  /** 本次启动是否已把知识库同步给教师端（静态数据，一次启动同步一次就够） */
  private kbSynced: boolean = false;
  /** 正在重新生成的消息 id，0 = 空闲。防连点，也防同时对两条回答发起重生成 */
  private regeneratingId: number = 0;
  /** 长按气泡弹出的菜单：目标消息 id，0 = 不显示 */
  @State bubbleMenuId: number = 0;
  /** 已进入「选取文字」模式的消息 id，0 = 无。该条 Text 打开原生选取 */
  @State selectingMsgId: number = 0;
  /**
   * 热启动快路径：EntryAbility.onNewWant 收到 deep link 时同步写这里，
   * @Watch 立刻响应，不走 preferences 的异步读写 —— 避开
   * 「onPageShow 的 checkScanParams 抢在 handleDeepLink 落盘之前读」的竞态。
   * 冷启动仍走 preferences（那时页面还没创建，@StorageLink 初始化不会触发 @Watch）。
   */
  @StorageLink('pendingSpot') @Watch('onPendingSpotChanged') pendingSpot: string = '';
  /**
   * 扫码去重：同一个原始串在 1.5 秒内只处理一次。
   * 热启动时两条通道都会送达同一次扫码（onNewWant 同时写了 AppStorage 和 preferences，
   * @Watch 与 onPageShow 各消费一次），不去重就会出两张卡片。
   */
  private lastScanRaw: string = '';
  private lastScanAt: number = 0;
  /** 打卡记录全量（读取时按 userKeyId 过滤归属） */
  @State checkins: CheckinRecord[] = [];
  /**
   * 当前用户 id（UserInfo.id）；0 = 游客 / 未登录。
   * 用 @State 而不是普通字段：它在 loadUserInfo 之后才确定，
   * 不是 @State 的话打卡归属判定不会重算，颜色会停在游客视图。
   */
  @State userKeyId: number = 0;
  /**
   * 当前用户的 username；未登录为空串。
   * 路线按用户隔离的 key 用它而不是 userKeyId —— 管理员的 id 是 0，
   * 会和「游客/未登录」的 0 撞车，username 是唯一的不会。
   */
  @State userKeyName: string = '';
  @State showRouteDialog: boolean = false;
  /** 全屏路线页：显隐 + 内容 */
  @State showRouteView: boolean = false;
  @State routePlan: RoutePlan = { intro: '', stops: [] };
  /**
   * 路线页当前显示多少个站点 —— 生成时从 0 逐张涨到总数，形成"流式生成"。
   * 重新打开已存路线时必须直接置为总数，否则会把浮现动画再播一遍。
   */
  @State routeStopsVisible: number = 0;
  /** 出题测试：全屏页显隐 + 阶段 */
  @State showQuizView: boolean = false;
  /** 'generating' 出题中 | 'answering' 作答中 | 'grading' 判分中 | 'done' 已出分 */
  @State quizStage: string = 'generating';
  /** 本次试卷对应的学段规格。出题、判分、界面上的分值和题数都读它 */
  @State quizSpec: QuizSpec = QUIZ_SPEC_PRIMARY;
  /** 本次试卷的学段（小学/中学/大学），上传和本地保存都用它 */
  @State quizGrade: string = '小学';
  @State quizQuestions: QuizQuestion[] = [];
  /** 与 quizQuestions 等长；未答为空串 */
  @State quizAnswers: string[] = [];
  @State quizScore: number = 0;
  @State quizRanking: QuizRankItem[] = [];
  @State quizMe: QuizRankItem | null = null;
  @State quizError: string = '';
  /** 已考过并本地存过卷子；再点「出题测试」直接展示上次成绩，不重新出题 */
  @State hasQuizRecord: boolean = false;
  /**
   * 上传/排名环节的提示。空串 = 一切正常。
   * 必须有这个：以前上传失败只打日志、排名为空就整段不渲染，
   * 界面上表现成「只有分数没有排名」，看不出是后端没起还是接口报错。
   */
  @State quizRankNote: string = '';
  /** 简答批改的提示（走了兜底基础分时会说明）。空串 = 正常 */
  @State quizGradeNote: string = '';
  /** 本次测试的截止时间戳（墙上时钟）。0 = 尚未开始计时 */
  @State quizDeadlineMs: number = 0;
  /** 剩余秒数。每秒按截止时间戳重算，仅供界面显示 */
  @State quizRemainSec: number = 0;
  /** 答题卡是否展开 */
  @State showAnswerSheet: boolean = false;
  /** 作答区的 List 控制器 —— 答题卡按题号跳转必须用它 */
  private quizScroller: Scroller = new Scroller();
  /** 倒计时定时器句柄，-1 = 未启动 */
  private quizTimerId: number = -1;
  /** 倒计时心跳计数，用来决定何时把进度落盘 */
  private quizTickCount: number = 0;
  /** 是否已存过路线；true 时「规划路线」直接打开，不再弹选择框 */
  @State hasRoute: boolean = false;
  /** 已保存路线的参数（与选择框的工作值 selectedGrade/selectedHours 分开，取消选择不会污染它） */
  @State routeGrade: string = '小学';
  @State routeHours: string = '1h';
  /** 关掉路线页后，在「规划路线」按钮上方冒出的提示气泡 */
  @State showRouteHint: boolean = false;
  /** 这个气泡是否已经弹过。持久化 —— 「只显示一次」指装了 App 只出现一次，不是每次启动一次 */
  @State routeHintShown: boolean = false;
  /** 生成中遮罩（路线规划 / 研学报告共用） */
  @State showGenerating: boolean = false;
  @State generatingText: string = '小智生成中，请稍候…';
  @State selectedGrade: string = '小学';
  @State selectedHours: string = '1h';
  @State previewVisible: boolean = false;
  @State previewPixelMap: image.PixelMap | null = null;
  @State showHistory: boolean = false;
  @State sessions: SessionData[] = [];
  /** 当前打开操作菜单的会话 id；0 = 无菜单 */
  @State menuSessionId: number = 0;
  /** 正在改名的会话 id；0 = 无 */
  @State renamingSessionId: number = 0;
  @State renameText: string = '';
  /** 分享面板是否打开，以及分享的是哪个会话 */
  @State showSharePanel: boolean = false;
  @State shareSessionId: number = 0;
  @State currentSessionId: number = 0;
  @State currentRole: string = 'student';
  @State isLoggedIn: boolean = false;
  /** 侧边栏展示用的昵称与头像首字（loadUserInfo 写入，游客/未登录有兜底） */
  @State userName: string = '未登录';
  @State userInitial: string = '游';
  /** 聊天区字号，由账号管理页设置，经 preferences 持久化；仅作用于阅读型文字 */
  @State chatFontSize: number = 16;
  /** 头像照片（侧边栏 40vp 小头像与账号管理页共用同一张），null 表示显示兜底色 + 首字 */
  @State avatarPixelMap: image.PixelMap | null = null;
  /** 「猜你想问」逐个弹出的进度：第 i 个 chip 在 suggestShown > i 时显示 */
  @State suggestShown: number = 0;
  /**
   * 气泡最大宽度（vp）。用确定数值替代百分比 '88%'，
   * 避免 List 虚拟化下"先测宽、后换行"导致容器高度算少、文字溢出气泡底部。
   */
  private bubbleMaxW: number = 300;

  @State isRecording: boolean = false;
  @State recordingDuration: number = 0;
  @State isRecognizing: boolean = false;
  @State voiceWaveLevel: number = 0;
  @State showVoicePanel: boolean = false;
  @State cancelRecording: boolean = false;

  @State currentLat: number = 0;
  @State currentLng: number = 0;
  @State isGeoListening: boolean = false;
  private lastTriggeredId: string = '';
  private lastTriggeredTime: number = 0;
  private readonly triggerCooldown: number = 10000;
  private geoUpdateTimer: number = -1;

  // ==================== A2 多路感知融合 ====================
  /** 停留状态机（不可变，由 dwellTick 返回新对象） */
  private dwell: DwellState = { spotId: '', enterAt: 0, pushed: false };
  /** 最近一次用户输入的入口通道。仅作观测，每次 sendMessage 必然覆盖，无残留 */
  private lastEntryChannel: EntryChannel = EntryChannel.TEXT;

  // 自动滚动相关
  private scroller: Scroller = new Scroller();
  @State autoScrollEnabled: boolean = true;
  private isProgrammaticScroll: boolean = false;

  // 思考动画旋转角度
  @State rotateAngle: number = 0;
  private rotateTimer: number = -1;

  private knowledge: Knowledge = new Knowledge();
  private tts: TtsSpeaker = new TtsSpeaker();
  private aiService: AiService = new AiService();
  private conversationHistory: AIMessage[] = [];
  private prefStore: preferences.Preferences | null = null;
  /** 端侧长期记忆（分层记忆 L2 + 调度 L3）；当前点位也由它持有并持久化 */
  private memory: Memory = new Memory();
  /** A3：网络状态采集（fail-open，采集层失效不影响功能） */
  private netProbe: NetProbe = new NetProbe();
  /** A3：路由统计与决策日志 */
  private routerStats: RouterStats = new RouterStats();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private appToken: string = '';
  private backend: BackendService = new BackendService();

  private audioRecorder: media.AudioRecorder | null = null;
  private recordFilePath: string = '';
  private recordingTimer: number = -1;
  private waveTimer: number = -1;
  private maxRecordSeconds: number = 60;
  /** 最近一次语音识别是否因「服务不可用」失败（断网/超时/非200），用于区分「识别结果为空」 */
  private asrUnavailable: boolean = false;

  // ==================== 自动滚动方法 ====================
  private onMessagesChanged(): void {
    // 连滚三次：60ms 捕捉即时高度，220ms 等长回答（AI 回复可达 200+ 字）布局完成，
    // 560ms 覆盖键盘收起 / 换行重排这类更晚的布局变化
    setTimeout(() => { this.scrollToBottom(); }, 60);
    setTimeout(() => { this.scrollToBottom(); }, 220);
    setTimeout(() => { this.scrollToBottom(); }, 560);
  }

  /**
   * 滚到底部。
   * autoScrollEnabled 是「用户手动上翻时暂停自动跟随」的开关。
   * 此前只有置 false 的地方（List.onScrollStart）、没有恢复的地方，
   * 导致用户手动滚过一次后，自动跟随永久失效。恢复点见
   * sendMessage / newSession / switchToSession。
   */
  private scrollToBottom(): void {
    if (!this.autoScrollEnabled) return;
    this.isProgrammaticScroll = true;
    this.scroller.scrollEdge(Edge.Bottom);
    // 100 → 420：滚动距离较远时 ArkUI 报告 onScrollStart 可能晚于 100ms，
    // 那时标志已复位，会被误判成「用户手动上翻」而关掉 autoScrollEnabled，
    // 于是后续那次修正被跳过 —— 从列表顶部发问时就会停在原地不动。
    setTimeout(() => { this.isProgrammaticScroll = false; }, 420);
  }

  // ==================== 辅助方法 ====================
  private async logout(): Promise<void> {
    // 退出前先把进行中的测试按**当前账号**存好、并停掉倒计时。顺序不能反：
    // 下面第 722 行会把 userKeyName 清空，存晚了这份进度就落到「游客」名下了。
    // 不停表的话，退出后倒计时还在跑，可能在身份已经切换的情况下触发自动交卷。
    await this.saveQuizProgress();
    this.stopQuizTimer();
    const userManager: UserManager = new UserManager(this.context);
    await userManager.logout();
    this.appToken = '';
    this.userKeyId = 0;
    this.isLoggedIn = false;
    this.currentRole = 'student';
    this.messages = [new ChatMessage(0, 0, '你好，我是小智，松山战役智能讲解员，你可以问我任何关于松山战役的问题。', 'welcome.mp3')];
    this.conversationHistory = [];
    this.sessions = [];
    this.currentSessionId = 0;
    this.showHistory = false;
    this.userKeyName = '';
    // 路线按用户隔离，退出即从内存清掉；不清磁盘上那份，本人再登回来还在
    this.hasRoute = false;
    this.routePlan = { intro: '', stops: [] };
    this.routeStopsVisible = 0;
    this.routeHintShown = false;
    this.showRouteView = false;
    this.showRouteHint = false;
    // 测试成绩也按用户隔离，退出即从内存清掉（磁盘上那份留着，本人登回来还在）
    this.hasQuizRecord = false;
    this.quizQuestions = [];
    this.quizAnswers = [];
    this.quizScore = 0;
    this.quizRanking = [];
    this.quizMe = null;
    this.quizRankNote = '';
    this.showQuizView = false;
    // 学段是随人走的，退出就回到默认，别让下一个登录的人继承上一个人的
    this.selectedGrade = '小学';
    // 会话列表按账号隔离，退出登录只清内存、不动磁盘 —— 本人再登回来历史还在
    promptAction.showToast({ message: '已退出登录' });
  }

  private async loadUserInfo(): Promise<void> {
    const userManager: UserManager = new UserManager(this.context);
    this.appToken = await userManager.getToken();
    this.isLoggedIn = await userManager.isLoggedIn();
    const user = await userManager.getUser();
    if (user !== null && user.role !== '') {
      this.userKeyId = user.id;
      this.userKeyName = user.username;
      this.currentRole = user.role;
      const display: string = user.name !== '' ? user.name : user.username;
      this.userName = display !== '' ? display : '未登录';
      this.userInitial = display !== '' ? display.substring(0, 1) : '游';
    } else {
      this.userKeyId = 0;
      this.userKeyName = '';
      this.userName = '未登录';
      this.userInitial = '游';
    }
  }

  /**
   * 只要求「已登录」，不限角色 —— 登录后的游客也放行。
   * 用于所有登录用户都应当能用的功能。目前只有照片修复。
   *
   * ⚠️ 与 requireLogin() 的区别只在【是否卡游客】：
   *    未登录 → 两者都引导去登录页；登录后的游客 → 本方法放行，requireLogin() 拦下。
   */
  private requireLoginAllowTourist(): boolean {
    if (!this.isLoggedIn) {
      promptAction.showToast({ message: '请先登录后使用该功能' });
      router.pushUrl({ url: 'pages/LoginPage' });
      return false;
    }
    return true;
  }

  // 受限功能守卫：未登录提示登录；游客提示无权限
  private requireLogin(): boolean {
    if (!this.requireLoginAllowTourist()) return false;
    if (this.currentRole === 'tourist') {
      promptAction.showToast({ message: '游客模式不支持该功能，请使用学生/教师账号' });
      return false;
    }
    return true;
  }

  // 有效回答等级：学生按所选学段，游客/教师/管理员统一大学风格
  private effectiveGrade(): string {
    return (this.isLoggedIn && this.currentRole === 'student') ? this.selectedGrade : '大学';
  }

  private uploadPointProgress(point: GeoPoint): void {
    if (this.appToken === '') return;
    this.backend.uploadProgress(this.appToken, point.id, point.name)
      .catch((e: Error) => { console.error('上报进度失败: ' + e.message); });
  }

  private uploadReport(reportText: string, duration: number): void {
    if (this.appToken === '') return;
    this.backend.uploadReport(this.appToken, reportText, duration)
      .catch((e: Error) => { console.error('上传报告失败: ' + e.message); });
  }

  /**
   * 上报打卡给教师端。未登录直接返回（和另外三个上传同一规矩）。
   * 失败只记日志，不打扰用户 —— 本地记录已经写好了，教师端少一条不影响学生端体验。
   */
  private uploadCheckin(spot: SpotEntry, source: string): void {
    if (this.appToken === '') return;
    this.backend.uploadCheckin(this.appToken, spot.key, spot.label, source)
      .catch((e: Error) => { console.error('上传打卡失败: ' + e.message); });
  }

  /** 上报当前路线给教师端。后端按 user_id 覆盖 */
  private uploadRoute(): void {
    if (this.appToken === '') return;
    const labels: string[] = [];
    for (let i = 0; i < this.routePlan.stops.length; i++) labels.push(this.routePlan.stops[i].name);
    this.backend.uploadRoute(this.appToken, this.routeGrade, this.routeHours, JSON.stringify(labels))
      .catch((e: Error) => { console.error('上传路线失败: ' + e.message); });
  }

  /**
   * 上报「这次回答命中了 App 知识库的哪一条」—— 教师端的热门知识点以 App 知识库为准。
   * 定位方式：取候选集，找 answer 与本次回答**逐字相同**的那条。
   * 定位不到就不报 —— 宁可少报，也不能把错的知识点算进热度。
   */
  private reportKnowledgeHit(query: string, answer: string): void {
    if (this.appToken === '' || answer === '') return;
    const hits: KnowledgeHit[] = this.knowledge.rankCandidates(query, 10);
    for (let i = 0; i < hits.length; i++) {
      if (hits[i].answer !== answer) continue;
      this.backend.uploadKnowledgeHit(this.appToken, hits[i].id, hits[i].question)
        .catch((e: Error) => { console.error('上报知识点命中失败: ' + e.message); });
      return;
    }
  }

  private uploadPhotoComparison(beforeBuffer: ArrayBuffer, afterBuffer: ArrayBuffer): void {
    if (this.appToken === '') return;
    const beforeBase64: string = 'data:image/jpeg;base64,' + buffer.from(beforeBuffer).toString('base64');
    const afterBase64: string = 'data:image/jpeg;base64,' + buffer.from(afterBuffer).toString('base64');
    this.backend.uploadPhoto(this.appToken, beforeBase64, afterBase64)
      .catch((e: Error) => { console.error('上传照片失败: ' + e.message); });
  }

  aboutToAppear() {
    const welcomeMsg = new ChatMessage(0, 0, '你好，我是小智，松山战役智能讲解员，你可以问我任何关于松山战役的问题。', 'welcome.mp3');
    this.messages = [welcomeMsg];
    if (this.voiceEnabled) this.playAudio(welcomeMsg);
    this.loadCheckins();
    // 会话列表和路线都按用户隔离，必须等用户标识就绪再读，合并成一个顺序调用
    this.loadUserScopedData();
    this.checkScanParams();
    this.requestLocationPermission();
    // A3：订阅网络变化。状态在每次 snapshot(fb, now) 时实时取，此处仅作唤醒
    this.netProbe.start(() => {});

    // TTS 预热：不 await，App 启动不被引擎创建阻塞；失败由 TtsSpeaker 静默吞掉
    this.tts.prewarm();

    // 气泡最大宽度：屏宽 × 88% − Row 左右 padding 24vp，取整为确定数值
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.bubbleMaxW = Math.floor(px2vp(d.width) * 0.88) - 24;
    } catch (e) {
      this.bubbleMaxW = 300;
      console.error('获取屏幕宽度失败: ' + (e as Error).message);
    }

    this.rotateTimer = setInterval(() => {
      this.rotateAngle = (this.rotateAngle + 5) % 360;
    }, 100);
  }

  /**
   * 页面重新可见时触发（含首次显示）。
   * 注意：aboutToAppear 只在组件创建时跑一次，从账号管理页返回不会重跑，所以两件事都挂这里。
   * ArkTS 不允许同名生命周期方法重复定义，必须合并为一个。
   */
  onPageShow(): void {
    this.loadFontSize();
    this.applyPendingLogout();
    // 扫码回读不能只挂 aboutToAppear：App 已在运行时扫码走的是 onNewWant，
    // 参数写进了 scan_params 但没人读，表现为「扫码没反应」，用户会以为码坏了。
    // 冷启动时这次调用读到的已是空值（aboutToAppear 那次已删除），是安全的重入。
    this.checkScanParams();
  }

  /** 读取账号管理页设置的字号，越界则保持现状 */
  private async loadFontSize(): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getPrefs();
      const size: number = await pref.get('chat_font_size', 16) as number;
      if (size >= 14 && size <= 22) {
        this.chatFontSize = size;
      }
      const photo: string = await pref.get('avatar_photo', '') as string;
      // 先取旧的，赋新值后再释放旧的：onPageShow 每次都会跑，不释放会持续泄漏 PixelMap
      const oldAvatar: image.PixelMap | null = this.avatarPixelMap;
      this.avatarPixelMap = photo !== '' ? await AvatarStore.load(photo) : null;
      if (oldAvatar !== null) {
        try { oldAvatar.release(); } catch (e) {}
      }
    } catch (e) {
      console.error('读取字号失败: ' + (e as Error).message);
    }
  }

  /**
   * 处理账号管理页立下的退出标记（与 checkScanParams 同款的 preferences 信号模式）。
   * 标记是一次性的：读到即删，避免之后每次返回都重复登出。
   * 命中时复用本组件的 logout()，因为清聊天记录 / 会话那几步（隐私）不能省。
   */
  private async applyPendingLogout(): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getPrefs();
      const flag: string = await pref.get('pending_logout', '') as string;
      if (flag === '1') {
        await pref.delete('pending_logout');
        await pref.flush();
        await this.logout();
        // 退出后身份变成「游客」，重新加载属于游客的那份数据
        await this.loadUserScopedData();
        return;
      }
    } catch (err) {
      console.error('处理退出标记失败: ' + (err as Error).message);
    }
    // 从登录页/账号页返回时用户可能变了；会话和路线都按用户隔离，要跟着重载
    await this.loadUserScopedData();
  }

  aboutToDisappear(): void {
    this.netProbe.stop();
    this.tts.shutdown();
    this.stopRecordingCleanup();
    if (this.audioRecorder) { try { this.audioRecorder.release(); } catch (e) {} this.audioRecorder = null; }
    for (let i = 0; i < this.messages.length; i++) {
      try {
        if (this.messages[i].imagePixelMap) this.messages[i].imagePixelMap!.release();
      } catch (e) {}
    }
    if (this.avatarPixelMap !== null) {
      try { this.avatarPixelMap.release(); } catch (e) {}
      this.avatarPixelMap = null;
    }
    this.stopGeoService();
    // 倒计时也得停：页面销毁后定时器还在跑的话，会在没有界面的情况下触发自动交卷
    this.stopQuizTimer();
    if (this.rotateTimer !== -1) {
      clearInterval(this.rotateTimer);
      this.rotateTimer = -1;
    }
  }

  // ==================== GPS自动讲解 ====================
  private async requestLocationPermission(): Promise<void> {
    const atManager = abilityAccessCtrl.createAtManager();
    const permissions: Array<Permissions> = [
      'ohos.permission.LOCATION',
      'ohos.permission.APPROXIMATELY_LOCATION'
    ];
    try {
      for (let perm of permissions) {
        const grantStatus = await atManager.requestPermissionsFromUser(this.context, [perm]);
        if (grantStatus.authResults[0] !== 0) {
          promptAction.showToast({ message: '需要定位权限才能自动讲解' });
          return;
        }
      }
      this.initGeoService();
    } catch (err) {
      console.error('权限请求失败: ' + JSON.stringify(err));
    }
  }

  private initGeoService(): void {
    try {
      this.geoUpdateTimer = setInterval(() => {
        const request = { timeoutMs: 3000 } as geoLocationManager.CurrentLocationRequest;
        geoLocationManager.getCurrentLocation(request).then((location) => {
          if (location && location.latitude !== undefined && location.longitude !== undefined) {
            this.currentLat = location.latitude;
            this.currentLng = location.longitude;
            this.checkNearbyPoints(location.latitude, location.longitude);
          }
        }).catch((err: BusinessError) => {
          console.error('获取位置失败: ' + err.message);
        });
      }, 5000);
      this.isGeoListening = true;
      console.info('GPS自动讲解服务已启动（轮询方式）');
    } catch (err) {
      console.error('启动GPS失败: ' + (err as Error).message);
      promptAction.showToast({ message: '无法获取位置，请确认GPS已开启' });
    }
  }

  private stopGeoService(): void {
    if (this.geoUpdateTimer !== -1) {
      clearInterval(this.geoUpdateTimer);
      this.geoUpdateTimer = -1;
    }
    this.isGeoListening = false;
  }

  /**
   * @param now 注入时间。生产不传 → Date.now()，行为与旧版一致；
   *            测试页传任意时刻，才能验「同坐标不同时段」和「停留 45 秒」。
   */
  private checkNearbyPoints(lat: number, lng: number, now: number = Date.now()): void {
    if (!this.isLoggedIn || this.currentRole === 'tourist') return;

    // 第一趟：找出本轮命中的点位（下标最小者优先，与旧版 break on first match 一致）。
    // 注意：只有【在半径内】才 break —— 不在半径内的点位要接着走「离开判定」。
    let hitIndex: number = -1;
    for (let i = 0; i < GEO_POINTS.length; i++) {
      const point: GeoPoint = GEO_POINTS[i];
      const decision: PerceptDecision = perceive(point, lat, lng, now);
      if (decision.inside) {
        hitIndex = i;
        break;
      }
      // 离开判定：越过迟滞区才算真的走了，迟滞区内保持原状态
      if (!decision.inHysteresis && this.lastTriggeredId === point.id) {
        this.lastTriggeredId = '';
      }
    }

    const inside: boolean = hitIndex >= 0;
    const pointId: string = inside ? GEO_POINTS[hitIndex].id : '';

    // 立即讲解：只在【进入点位那一刻】判定一次，后续轮询不再补触发。
    // 原因：冷却 10s < 轮询间隔 5s×2，补触发会永远抢在停留提示前面，使停留提示不可达。
    const isNewEntry: boolean = inside && this.dwell.spotId !== pointId;
    let autoExplain: boolean = false;
    if (isNewEntry && this.lastTriggeredId !== pointId
        && now - this.lastTriggeredTime >= this.triggerCooldown) {
      const point: GeoPoint = GEO_POINTS[hitIndex];
      this.lastTriggeredId = pointId;
      this.lastTriggeredTime = now;
      autoExplain = true;
      this.triggerGeoExplain(point, now, perceive(point, lat, lng, now));
    }

    // 停留状态机：每个轮询【只迁一次】，用「本轮命中哪个点位」驱动。
    // 若放在上面的循环里逐点位调，未命中点位会把 spotId 清空，
    // 下一轮再看命中点位就判成「新进入」，enterAt 被无限重置、阈值永远攒不满。
    const event: DwellEvent = dwellTick(this.dwell, pointId, inside, autoExplain, now);
    this.dwell = event.next;
    if (event.push && inside) this.pushDwellHint(GEO_POINTS[hitIndex], now);
  }

  private async triggerGeoExplain(point: GeoPoint, now: number = Date.now(),
                                  decision: PerceptDecision | null = null): Promise<void> {
    // GPS 走到点位也算「到达」—— 学生不打卡时，记忆的空间分也要有依据。
    // 直接用 point.spotKey，不再靠 name 反查 ——
    // name 是显示名，与 RoutePlanner 的匹配标识不是一套
    //（'松山战役纪念碑' 反查 findSpot 会落空，这是批次 2 的遗留缺口）。
    // spotKey 为空时【主动清空】currentSpot：学生确实站在这个点上，
    // 宁可「不知道在哪」，也不要错误地归到上一个点位头上（fail-closed）。
    await this.memory.setCurrentSpot(this.context, point.spotKey);

    // 时段命中的内容由 perceive 决定；调用方不传则回落点位默认（旧调用点不受影响）
    const query: string = decision !== null ? decision.knowledgeQuery : point.knowledgeQuery;
    const fallbackAudio: string = decision !== null ? decision.audioFile : point.audioFile;
    const answer = this.knowledge.search(query);
    if (answer !== '') {
      const msg = new ChatMessage(now, 0, `【自动讲解】${point.name}：${answer}`, fallbackAudio);
      if (!this.isIgnoredText(answer)) msg.isKnowledge = true;
      this.messages = this.messages.concat([msg]);
      this.uploadPointProgress(point);
      if (this.voiceEnabled) this.playAudio(msg);
      await this.saveCurrentSession();
    }
  }

  /**
   * 停留超时提示 —— 温和地问一句，不是重复讲解。
   * 与 triggerGeoExplain 的区别：不检索知识、不发声、不写记忆、不计打卡。
   * 它只是一个「要不要听听」的邀请，用户答不答由他自己决定。
   */
  private async pushDwellHint(point: GeoPoint, now: number): Promise<void> {
    const msg = new ChatMessage(now, 0,
      `你在这儿停了一会儿 —— 要听听${point.name}的故事吗？`, '');
    this.messages = this.messages.concat([msg]);
    await this.saveCurrentSession();
  }

  // ==================== 语音录制 ====================
  private formatDuration(seconds: number): string {
    const min = Math.floor(seconds / 60);
    const sec = seconds % 60;
    return (min < 10 ? '0' + min : '' + min) + ':' + (sec < 10 ? '0' + sec : '' + sec);
  }

  private async startRecording(): Promise<void> {
    if (this.isRecording) return;
    this.tts.stopSpeaking();
    this.isRecording = true;
    this.cancelRecording = false;
    this.recordingDuration = 0;
    this.voiceWaveLevel = 0;
    this.showVoicePanel = true;
    try {
      this.recordFilePath = this.context.tempDir + '/voice_' + Date.now() + '.m4a';
      this.audioRecorder = await media.createAudioRecorder();
      const config: media.AudioRecorderConfig = {
        audioEncoder: media.AudioEncoder.AAC_LC,
        audioEncodeBitRate: 128000,
        audioSampleRate: 16000,
        numberOfChannels: 1,
        uri: 'file://' + this.recordFilePath
      };
      this.audioRecorder.on('error', (err: BusinessError) => {
        this.stopRecordingCleanup();
        this.showVoicePanel = false;
        promptAction.showToast({ message: '录音出错，请重试' });
      });
      await this.audioRecorder.prepare(config);
      await this.audioRecorder.start();
      this.recordingTimer = setInterval(() => {
        this.recordingDuration++;
        if (this.recordingDuration >= this.maxRecordSeconds) this.stopAndRecognize();
      }, 1000);
      this.waveTimer = setInterval(() => {
        if (this.isRecording) this.voiceWaveLevel = Math.floor(Math.random() * 5) + 1;
      }, 150);
    } catch (err) {
      this.stopRecordingCleanup();
      this.showVoicePanel = false;
      promptAction.showToast({ message: '录音启动失败，请检查麦克风权限' });
    }
  }

  private async stopAndRecognize(): Promise<void> {
    if (!this.isRecording) return;
    const duration = this.recordingDuration;
    this.stopRecordingCleanup();
    if (duration < 1) { this.showVoicePanel = false; promptAction.showToast({ message: '录音时间太短' }); this.deleteRecordFile(); return; }
    if (this.cancelRecording) { this.showVoicePanel = false; this.deleteRecordFile(); return; }
    this.isRecognizing = true;
    try {
      const text = await this.speechToText(this.recordFilePath);
      this.isRecognizing = false;
      this.showVoicePanel = false;
      if (text) {
        this.inputText = text;
        await this.sendMessage(EntryChannel.VOICE);
      } else if (this.asrUnavailable) {
        promptAction.showToast({ message: '语音识别需要联网，离线时请用文字提问' });
      } else {
        promptAction.showToast({ message: '未识别到语音内容，请重试' });
      }
    } catch (err) {
      this.isRecognizing = false;
      this.showVoicePanel = false;
      promptAction.showToast({ message: '语音识别失败' });
    }
    this.deleteRecordFile();
  }

  private cancelCurrentRecording(): void {
    this.cancelRecording = true;
    this.stopRecordingCleanup();
    this.showVoicePanel = false;
    this.deleteRecordFile();
  }

  private stopRecordingCleanup(): void {
    this.isRecording = false;
    this.voiceWaveLevel = 0;
    if (this.recordingTimer !== -1) { clearInterval(this.recordingTimer); this.recordingTimer = -1; }
    if (this.waveTimer !== -1) { clearInterval(this.waveTimer); this.waveTimer = -1; }
    if (this.audioRecorder) {
      try { this.audioRecorder.stop(); } catch (e) {}
      try { this.audioRecorder.release(); } catch (e) {}
      this.audioRecorder = null;
    }
  }

  private deleteRecordFile(): void {
    if (this.recordFilePath) {
      try { fs.unlinkSync(this.recordFilePath); } catch (e) {}
      this.recordFilePath = '';
    }
  }

  private async speechToText(filePath: string): Promise<string> {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(filePath);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      file = null;
      const b64 = buffer.from(buf).toString('base64');
      const httpRequest = http.createHttp();
      try {
        const audioPart: AIContentPart = { type: 'audio', audio: { data: b64, format: 'm4a' } };
        const textPart: AIContentPart = { type: 'text', text: '转录为文字，只输出文字，不要任何解释。' };
        const userMessage: AIChatMessage = { role: 'user', content: [audioPart, textPart] };
        const requestBody: AIRequestBody = {
          model: 'Qwen/Qwen2-Audio-7B-Instruct',
          messages: [userMessage],
          max_tokens: 200,
          temperature: 0.1
        };
        const response = await httpRequest.request(this.aiService.aiUrl, {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.aiService.aiKey}` },
          extraData: JSON.stringify(requestBody),
          connectTimeout: 10000, readTimeout: 30000
        });
        if (response.responseCode !== 200) throw new Error('API Error');
        let resultStr: string = typeof response.result === 'string'
          ? response.result
          : buffer.from(response.result as ArrayBuffer).toString('utf-8');
        const jsonResult = JSON.parse(resultStr) as AIResponseBody;
        if (jsonResult.choices && jsonResult.choices.length > 0) {
          this.asrUnavailable = false;
          return jsonResult.choices[0].message.content.trim();
        }
        throw new Error('Format Error');
      } finally { httpRequest.destroy(); }
    } catch (err) {
      // 语音识别走的是云端 Qwen2-Audio（非端侧 ASR），断网/超时都会落到这里
      console.error('语音转文字失败: ' + (err as Error).message);
      this.asrUnavailable = true;
      return '';
    } finally {
      if (file) try { fs.closeSync(file); } catch (e) {}
    }
  }

  // ==================== 持久化 ====================
  private async getPrefs(): Promise<preferences.Preferences> {
    if (this.prefStore !== null) return this.prefStore;
    try { this.prefStore = await preferences.getPreferences(this.context, PREF_STORE_NAME); }
    catch (err) { console.error('Preferences 初始化失败: ' + JSON.stringify(err)); }
    return this.prefStore!;
  }

  // ==================== 会话改名 / 分享 ====================

  /** 打开改名弹层，预填当前名称 */
  private openRenameFor(sessionId: number): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === sessionId) {
        this.renameText = this.sessions[i].title;
        break;
      }
    }
    this.renamingSessionId = sessionId;
    this.menuSessionId = 0;
  }

  /** 确认改名并落盘。saveCurrentSession 已保留 customTitle，不会被首条消息冲掉 */
  private async confirmRename(): Promise<void> {
    const name: string = this.renameText.trim();
    if (name === '') {
      promptAction.showToast({ message: '名称不能为空' });
      return;
    }
    const targetId: number = this.renamingSessionId;
    this.renamingSessionId = 0;
    // 走 setSessionTitle 而不是原地 sessions[i].title = name：
    // 原地改属性 @State 观察不到（SessionData 是 interface，不是 @Observed），
    // 侧边栏那一行不会刷新，改名要等下次其它操作才显示出来。
    await this.setSessionTitle(targetId, name, true);
    promptAction.showToast({ message: '已重命名' });
  }

  /** 打开分享面板 */
  private openShareFor(sessionId: number): void {
    this.shareSessionId = sessionId;
    this.menuSessionId = 0;
    this.showSharePanel = true;
  }

  /** 拼装分享文本：标题 + 全部问答 */
  private buildShareText(sessionId: number): string {
    for (let i = 0; i < this.sessions.length; i++) {
      const s: SessionData = this.sessions[i];
      if (s.id !== sessionId) continue;
      let out: string = '【松山战役研学对话】' + s.title + '\n\n';
      for (let j = 0; j < s.messages.length; j++) {
        const m: ChatMessageData = s.messages[j];
        if (m.id === 0 || m.text === '') continue;
        out += (m.type === 1 ? '我：' : '小智：') + m.text + '\n';
      }
      out += '\n—— 来自「松山战役数字研学」';
      return out;
    }
    return '';
  }

  /** 该对话里第一条用户提问 —— 用作深链的 question 参数 */
  private firstUserQuestion(sessionId: number): string {
    for (let i = 0; i < this.sessions.length; i++) {
      const s: SessionData = this.sessions[i];
      if (s.id !== sessionId) continue;
      for (let j = 0; j < s.messages.length; j++) {
        const m: ChatMessageData = s.messages[j];
        if (m.type === 1 && m.text !== '') return m.text;
      }
      return s.title;
    }
    return '';
  }

  /**
   * 复制深链。复用项目已有的深链机制，无需新增任何解析代码：
   *   module.json5 注册了 scheme=songshan / host=open
   *   → EntryAbility.handleDeepLink 解析 ?question= 并写入 scan_params
   *   → Index.checkScanParams 读回后自动发起同一提问
   * 所以链接在别人设备上（已装 App）也能触发同样的讲解。
   */
  private async copySessionLink(): Promise<void> {
    const q: string = this.firstUserQuestion(this.shareSessionId);
    if (q === '') {
      promptAction.showToast({ message: '这个对话还没有内容' });
      return;
    }
    await this.copyTextToClipboard('songshan://open?question=' + encodeURIComponent(q));
    promptAction.showToast({ message: '链接已复制，对方装 App 即可看到同样讲解' });
  }

  /**
   * 会话操作菜单（bindMenu 的内容）。
   * bindMenu 自动锚定到被点的 ⋯ 按钮，并自动处理越界翻转 / 点击外部关闭。
   */
  @Builder
  sessionMenuBuilder(session: SessionData) {
    Column() {
      Button(session.isPinned ? '取消置顶' : '置顶')
        .width('100%').height(44).fontSize(15)
        .backgroundColor(Color.Transparent).fontColor('#FFE9A8')
        .onClick(() => { this.togglePin(session.id); })
      Button('编辑对话名称')
        .width('100%').height(44).fontSize(15)
        .backgroundColor(Color.Transparent).fontColor('#FFE9A8')
        .onClick(() => { this.openRenameFor(session.id); })
      Button('分享对话')
        .width('100%').height(44).fontSize(15)
        .backgroundColor(Color.Transparent).fontColor('#FFE9A8')
        .onClick(() => { this.openShareFor(session.id); })
      Button('从对话列表删除')
        .width('100%').height(44).fontSize(15)
        .backgroundColor(Color.Transparent).fontColor('#FF8A8A')
        .onClick(() => {
          this.menuSessionId = 0;
          this.deleteSession(session.id);
        })
    }
    .width(180)
  }

  /**
   * 下一个会话名「对话N」。
   * 用持久化计数器而不是 sessions.length + 1 —— 后者删过会话后会重号
   * （已有「对话3」，删掉一个，再新建又叫「对话3」）。
   * 老会话不做迁移，只对新会话生效。
   */
  private async nextSessionTitle(): Promise<string> {
    try {
      const pref: preferences.Preferences = await this.getPrefs();
      const seq: number = await pref.get(this.sessionSeqKey(), 0) as number;
      const next: number = seq + 1;
      await pref.put(this.sessionSeqKey(), next);
      await pref.flush();
      return '对话' + next;
    } catch (err) {
      console.error('生成会话序号失败: ' + JSON.stringify(err));
      return '对话' + (this.sessions.length + 1);
    }
  }

  /** 排序：置顶优先，其次 timestamp 降序（新的在上） */
  private sortedSessions(): SessionData[] {
    const list: SessionData[] = this.sessions.slice();
    list.sort((a: SessionData, b: SessionData): number => {
      const pa: number = a.isPinned ? 1 : 0;
      const pb: number = b.isPinned ? 1 : 0;
      if (pa !== pb) return pb - pa;
      return b.timestamp - a.timestamp;
    });
    return list;
  }

  /** 持久化当前 sessions 数组 */
  private async persistSessions(): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getPrefs();
      await pref.put(this.sessionsKey(), JSON.stringify(this.sessions));
      await pref.flush();
    } catch (err) {
      console.error('持久化会话失败: ' + JSON.stringify(err));
    }
  }

  /** 兜底标题：用户问题去掉首尾空白后截前 20 字 */
  private fallbackTitle(question: string): string {
    const q: string = question.trim();
    return q.length > 20 ? q.substring(0, 20) : q;
  }

  /**
   * 本会话里是否已有用户提问。
   * 用 type === 1 扫，而不是复用 isNewChat() —— 后者依赖「只有一条 id 为 0 的欢迎语」，
   * 若新会话里先触发过 GPS 自动讲解（type 0），isNewChat() 会返回 false，
   * 导致用户第一次真正提问时标题不生成。
   */
  private hasUserMessage(): boolean {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].type === 1) return true;
    }
    return false;
  }

  /** 清掉引号/标点/换行并压到 maxLen 字以内；返回空串表示这条标题不可用 */
  private sanitizeTitle(raw: string, maxLen: number): string {
    let t: string = raw.replace(/[\r\n]+/g, ' ');
    t = t.replace(/["'“”‘’《》〈〉【】「」（）()*#]/g, '');
    t = t.replace(/[。，、；：！？,.!?;:]/g, ' ');
    t = t.replace(/\s+/g, ' ').trim();
    if (t.length > maxLen) t = t.substring(0, maxLen);
    return t.trim();
  }

  /**
   * 改标题并落盘。byUser = true 表示用户手动改名，同时把会话标记为「标题已锁定」。
   * 必须整体替换 sessions 数组：SessionData 是 interface 不是 @Observed，
   * 原地改 s.title 观察不到；且 ForEach 键里含 title，键变了这一行才会重建。
   */
  private async setSessionTitle(sessionId: number, newTitle: string, byUser: boolean): Promise<void> {
    let found: boolean = false;
    const next: SessionData[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      const s: SessionData = this.sessions[i];
      if (s.id !== sessionId) {
        next.push(s);
        continue;
      }
      found = true;
      // 已锁定（用户改过名）的不许自动覆盖；用户自己改则放行并上锁
      if (!byUser && s.isCustomTitle) {
        next.push(s);
        continue;
      }
      const updated: SessionData = {
        id: s.id, title: newTitle, messages: s.messages, history: s.history,
        timestamp: s.timestamp, isPinned: s.isPinned,
        isCustomTitle: byUser ? true : (s.isCustomTitle ? true : false)
      };
      next.push(updated);
    }
    // 会话在等待期间被删掉了 —— 直接放弃，绝不重建（否则会复活已删除的会话）
    if (!found) return;
    this.sessions = next;
    await this.persistSessions();
  }

  /**
   * 首条用户消息触发的自动标题。不阻塞 sendMessage：调用方不 await。
   * 兜底标题由 saveCurrentSession 在首次落盘时写入，这里只负责「升级成 AI 总结」。
   * 调用点在 sendMessage 最末尾（本轮问答的模型调用已全部结束），因此不与问答并发抢账号。
   * 目标会话按 id 定位、不用 currentSessionId —— 总结期间用户可能已切走、甚至删掉它。
   */
  private async applyAutoTitle(sessionId: number, question: string): Promise<void> {
    let raw: string = '';
    try {
      raw = await this.aiService.summarizeTitle(question);
    } catch (err) {
      // 离线/超时/状态码非 200：兜底标题已生效，什么都不用做
      console.error('[TITLE] AI 总结失败，保留兜底标题: ' + (err as Error).message);
      return;
    }
    const clean: string = this.sanitizeTitle(raw, 12);
    if (clean === '') return;
    await this.setSessionTitle(sessionId, clean, false);
  }

  /** 切换置顶状态并落盘 */
  private async togglePin(sessionId: number): Promise<void> {
    // 必须整体替换 sessions 数组：this.sessions[i].isPinned = x 是对普通对象的属性写入，
    // SessionData 是 interface 不是 @Observed，@State 观察不到。
    // 之前置顶针能出现，全靠末尾 menuSessionId = 0 顺带触发的重渲染 ——
    // 而菜单 overlay 退场期间那次重渲染会被推迟，看上去就是「过一会儿才显示」。
    let found: boolean = false;
    let pinnedNow: boolean = false;
    const next: SessionData[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      const s: SessionData = this.sessions[i];
      if (s.id !== sessionId) {
        next.push(s);
        continue;
      }
      found = true;
      pinnedNow = !(s.isPinned ? true : false);
      // 新建对象时必须把 isCustomTitle 一起带上，否则会把「用户改名锁定」冲掉
      next.push({
        id: s.id, title: s.title, messages: s.messages, history: s.history,
        timestamp: s.timestamp, isPinned: pinnedNow,
        isCustomTitle: s.isCustomTitle ? true : false
      });
    }
    if (!found) return;
    this.sessions = next;                      // 整体替换 → @State 立刻通知
    this.menuSessionId = 0;                    // 仍要清，它是「菜单展开」的哨兵值
    promptAction.showToast({ message: pinnedNow ? '已置顶' : '已取消置顶' });
    await this.persistSessions();
  }

  private async loadSessions(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const val = await pref.get(this.sessionsKey(), '');
      const sessionsStr: string = val as string;
      if (sessionsStr !== '') {
        const parsedList = JSON.parse(sessionsStr) as SessionData[];
        this.sessions = parsedList;
        if (this.sessions.length > 0) {
          const latest = this.sessions[this.sessions.length - 1];
          this.restoreSession(latest);
        }
      }
    } catch (err) { console.error('加载会话列表失败: ' + JSON.stringify(err)); }
  }

  private restoreSession(session: SessionData): void {
    this.currentSessionId = session.id;
    this.messages = [];
    for (let i = 0; i < session.messages.length; i++) {
      const msgData = session.messages[i];
      const msg = new ChatMessage(msgData.id, msgData.type, msgData.text, msgData.audioFile);
      msg.isKnowledge = msgData.isKnowledge;
      // 历史数据没有这三个字段，读到 undefined 时兜成空串
      msg.cardType = msgData.cardType ? msgData.cardType : '';
      msg.spotKey = msgData.spotKey ? msgData.spotKey : '';
      msg.spotSource = msgData.spotSource ? msgData.spotSource : '';
      this.messages.push(msg);
    }
    this.conversationHistory = [];
    for (let i = 0; i < session.history.length; i++) {
      this.conversationHistory.push({ role: session.history[i].role, content: session.history[i].content });
    }
    this.closeBubbleMenu();
  }

  private async saveCurrentSession(titleOverride: string = ''): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const messagesData: ChatMessageData[] = [];
      for (let i = 0; i < this.messages.length; i++) {
        const msg = this.messages[i];
        messagesData.push({
          id: msg.id, type: msg.type, text: msg.text,
          audioFile: msg.audioFile, isKnowledge: msg.isKnowledge,
          cardType: msg.cardType, spotKey: msg.spotKey, spotSource: msg.spotSource
        });
      }
      // 保留该会话已有的「置顶状态」与「自定义名称」。
      // 前者不保留会导致每次保存都把置顶清掉；后者不保留会被首条消息文本冲掉。
      let pinned: boolean = false;
      let customTitle: string = '';
      let isCustomTitle: boolean = false;
      for (let i = 0; i < this.sessions.length; i++) {
        if (this.sessions[i].id === this.currentSessionId) {
          pinned = this.sessions[i].isPinned ? true : false;
          customTitle = this.sessions[i].title;
          isCustomTitle = this.sessions[i].isCustomTitle ? true : false;
          break;
        }
      }
      // 全新启动未落过盘时 currentSessionId 初值为 0，会和 ⋯ 菜单「无展开」的哨兵值
      // （menuSessionId === 0）撞上，这里换成正数 id
      if (this.currentSessionId === 0) this.currentSessionId = Date.now();
      // 已有标题（含用户手动改过的名字）一律保留；
      // 新会话优先用调用方给的标题（首条消息 → 问题前 20 字），否则退回「对话N」
      const title: string = customTitle !== ''
        ? customTitle
        : (titleOverride !== '' ? titleOverride : await this.nextSessionTitle());
      const currentSession: SessionData = {
        id: this.currentSessionId, title: title,
        messages: messagesData, history: this.conversationHistory,
        timestamp: Date.now(), isPinned: pinned, isCustomTitle: isCustomTitle
      };
      // 重建新数组后整体替换，而不是 sessions[i] = x / push：
      // 整体替换对 @State 一定可观察；顺带把「20 条上限裁剪」合并成一次赋值
      let found: boolean = false;
      const next: SessionData[] = [];
      for (let i = 0; i < this.sessions.length; i++) {
        if (this.sessions[i].id === this.currentSessionId) {
          next.push(currentSession);
          found = true;
        } else {
          next.push(this.sessions[i]);
        }
      }
      if (!found) next.push(currentSession);
      this.sessions = next.length > 20 ? next.slice(next.length - 20) : next;
      await pref.put(this.sessionsKey(), JSON.stringify(this.sessions));
      await pref.flush();
    } catch (err) { console.error('保存会话失败: ' + JSON.stringify(err)); }
  }

  /**
   * 把对话框恢复成「新对话」：欢迎语 + 空历史 + 一个全新的、尚未落盘的会话 id。
   * 只改内存状态、不落盘 —— 落不落由调用方决定：
   * newSession 先存旧会话，deleteSession 则绝不能存（会把刚删的写回去）。
   */
  private resetToNewChat(): void {
    this.autoScrollEnabled = true;
    this.closeBubbleMenu();
    this.messages = [new ChatMessage(0, 0, '你好，我是小智，松山战役智能讲解员，你可以问我任何关于松山战役的问题。', 'welcome.mp3')];
    this.conversationHistory = [];
    this.currentSessionId = Date.now();
  }

  private async newSession(): Promise<void> {
    this.autoScrollEnabled = true;
    // 判断当前是否只有欢迎消息（即新对话）
    if (this.messages.length === 1 && this.messages[0].id === 0 &&
      this.messages[0].text.indexOf('你好，我是小智') !== -1) {
      promptAction.showToast({ message: '当前已是新对话' });
      return;
    }
    await this.saveCurrentSession();
    this.resetToNewChat();
    promptAction.showToast({ message: '已创建新对话' });
  }

  private async switchToSession(session: SessionData): Promise<void> {
    this.autoScrollEnabled = true;
    // 必须等落盘完再 restoreSession —— 后者会同步覆盖 messages / currentSessionId，
    // 而 saveCurrentSession 要等第一个 await 之后才读它们，不 await 会把内容存进错的会话
    await this.saveCurrentSession();
    this.restoreSession(session);
    this.showHistory = false;
    promptAction.showToast({ message: '已切换到历史对话' });
  }

  private async deleteSession(sessionId: number): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const newSessions = this.sessions.filter(s => s.id !== sessionId);
      this.sessions = newSessions;
      // 删的是当前会话 → 对话框回到「新对话」。
      // 必须在这里立刻重置 currentSessionId：否则下一次 saveCurrentSession 会因为在
      // sessions 里找不到该 id 而走 !found 分支，把刚删掉的会话整条写回列表。
      if (sessionId === this.currentSessionId) this.resetToNewChat();
      await pref.put(this.sessionsKey(), JSON.stringify(newSessions));
      await pref.flush();
      promptAction.showToast({ message: '已删除对话' });
    } catch (err) {
      console.error('删除会话失败: ' + JSON.stringify(err));
      promptAction.showToast({ message: '删除失败' });
    }
  }

  // ==================== 语音播报（TTS） ====================
  /**
   * 朗读一条消息 —— 全走系统 TTS。
   *
   * 预录 MP3 方案已弃用（只覆盖 5 条固定内容，范围太窄），matchAudio 的关键词猜测一并删除。
   * 引擎不可用时由 TtsSpeaker 静默降级：不弹错、不关播报开关、不打断对话。
   *
   * ⚠️ 这里【不】判 voiceEnabled —— 四个自动播报的调用点各自已经判过，
   *    而气泡菜单里的「朗读」是用户的显式操作，必须无视开关照样出声（与旧行为一致）。
   */
  private async playAudio(msg: ChatMessage): Promise<void> {
    if (msg.text === '') return;
    try {
      await this.tts.speak(msg.text);
    } catch (e) {
      // 播报永远不该影响对话主流程
      console.error('[TTS] playAudio 异常: ' + JSON.stringify(e));
    }
  }

  // ==================== 照片修复 ====================
  private async handlePhotoRepair(): Promise<void> {
    let photoUri: string = '';
    try {
      const photoPicker = new picker.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1
      });
      if (result.photoUris.length === 0) return;
      photoUri = result.photoUris[0];

      const file = fs.openSync(photoUri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(photoUri);
      const bufferData = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, bufferData);
      fs.closeSync(file);

      const imageSource1 = image.createImageSource(bufferData);
      let originalMapForUser: image.PixelMap | null = null;
      try {
        originalMapForUser = await imageSource1.createPixelMap();
      } catch (e) {
        const opts: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.RGBA_8888 };
        originalMapForUser = await imageSource1.createPixelMap(opts);
      }
      imageSource1.release();
      if (!originalMapForUser) throw new Error('无法解码图片');

      const userMsg = new ChatMessage(Date.now(), 1, '准备修复...');
      userMsg.imagePixelMap = originalMapForUser;
      userMsg.repairProgress = 0;
      this.messages = this.messages.concat([userMsg]);

      const progressMsg = new ChatMessage(Date.now() + 100, 0, '正在准备修复...');
      progressMsg.repairProgress = 0;
      this.messages = this.messages.concat([progressMsg]);

      let repairedBuffer: ArrayBuffer | null = null;
      let errorMessage: string = '';
      try {
        const progressCallback: RepairProgressCallback = (progress, text) => {
          progressMsg.repairProgress = progress;
          progressMsg.text = text;
          this.messages = this.messages.slice();
        };

        // ===== A3 路由预判：先判路，再上传 =====
        // 照片修复的 connectTimeout 比问答更长（实测断网要转约 30s），
        // 预判为端侧时跳过上传，立即走 repairImage 内部同一条本地增强路径。
        // 注：预判放在【原有 try 内部】，两个分支共用下面那个 catch ——
        //     所以 DEVICE 分支同样受 errorMessage 兜底，异常不会向上抛。
        const netState: NetworkState = this.netProbe.snapshot(
          this.routerStats.linkFeedback(), Date.now());
        const batState: BatteryState = {
          soc: batteryInfo.batterySOC,
          charging: batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
        };
        const decision: RouteDecision = route(
          TaskType.PHOTO_RESTORE, netState, batState,
          this.routerStats.statsOf(TaskType.PHOTO_RESTORE));

        if (decision.target === RouteTarget.DEVICE) {
          // 断网/弱网：不发起请求 —— 省掉约 30s 的 connectTimeout 白等
          this.routerStats.recordDecision(
            TaskType.PHOTO_RESTORE, decision, netState.tier, true, 0);
          console.info('[A3] 照片修复预判端侧: ' + decision.reason);

          if (netState.tier === NetTier.OFFLINE) {
            // 链路被判为不可用：不做本地增强、也不假装"AI 修复"，直接告诉用户稍后重试。
            //
            // ⚠️ 判据用 netState.tier，【不能】只看 decision.target ——
            //    target=DEVICE 还会被规则 4/5（失败率/延迟）命中，那时网络多半是通的，
            //    "彻底不修"会让本可降级成功的场景白白失败；那种情况仍走本地增强。
            //
            // ⚠️ tier=OFFLINE 【不止】来自真断网：fuseLink 的反馈层在连续失败 ≥3 次时
            //    同样会把 tier 顶到 OFFLINE（FAILURE_STREAK_THRESHOLD=3）。所以文案
            //    特意写成"暂时不可用…或稍后重试"，让 真断网 / pod 挂 / 401 累积 / 502
            //    四种触发源都自洽。**别把它改窄回"请检查网络"**。
            // ⚠️ 已知盲区：仿真器上 readSystem() 对断网无感，只能靠反馈层 —— 所以
            //    仿真器上"断网后的第一次修复"仍会降级（要连续失败 ≥3 次才拦得住）。
            errorMessage = '照片修复暂时不可用，请检查网络或稍后重试';
            promptAction.showToast({ message: errorMessage });
          } else {
            // 与云端降级路径用同一句文案，保证两种降级在界面上分不出差别
            progressCallback(50, 'AI 修复不可用，改用本地增强（非 AI）');
            repairedBuffer = await this.aiService.localEnhance(bufferData, progressCallback);
          }
        } else {
          repairedBuffer = await this.aiService.repairImage(
            bufferData, this.backend, this.appToken, progressCallback,
            (ok: boolean, ms: number) => {
              this.routerStats.markAttempt(TaskType.PHOTO_RESTORE, ms, ok);
              this.routerStats.recordDecision(
                TaskType.PHOTO_RESTORE, decision, netState.tier, ok, ms);
            });
        }
      } catch (e) {
        errorMessage = (e as Error).message || '修复调用失败';
        console.error('修复调用异常: ' + errorMessage);
      }

      this.removeMessageById(progressMsg.id);

      if (repairedBuffer) {
        const repairedImageSource = image.createImageSource(repairedBuffer);
        let repairedMap: image.PixelMap | null = null;
        try {
          repairedMap = await repairedImageSource.createPixelMap();
        } catch (e) {
          const opts: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.RGBA_8888 };
          repairedMap = await repairedImageSource.createPixelMap(opts);
        }
        repairedImageSource.release();
        if (repairedMap) {
          const replyMsg = new ChatMessage(Date.now() + 200, 0, '档案修复完成。已拂去岁月尘埃，严格保留了历史原貌。');
          replyMsg.imagePixelMap = repairedMap;
          this.messages = this.messages.concat([replyMsg]);
          this.uploadPhotoComparison(bufferData, repairedBuffer);
        } else {
          throw new Error('无法显示修复后的图片');
        }
      } else {
        const shortError = errorMessage ? (errorMessage.length > 150 ? errorMessage.substring(0, 150) + '...' : errorMessage) : '未知错误';
        const failMsg = new ChatMessage(Date.now() + 200, 0, '❌ 修复失败：' + shortError);
        this.messages = this.messages.concat([failMsg]);
        promptAction.showToast({ message: '修复失败: ' + shortError });
      }
      await this.saveCurrentSession();
    } catch (err) {
      let errMsg = '未知错误';
      if (typeof err === 'string') {
        errMsg = err;
      } else if (err instanceof Error) {
        errMsg = err.message;
      } else {
        errMsg = JSON.stringify(err) || '未知错误';
      }
      console.error('照片处理整体异常: ' + errMsg);
      promptAction.showToast({ message: '照片处理失败: ' + errMsg });
      await this.saveCurrentSession();
    }
  }

  // ==================== 知识库查询 ====================
  private async searchKnowledge(query: string): Promise<string> {
    const q = query.trim().toLowerCase();
    // ⚠️ 这里只放【主题明确】的映射。通用后缀（怎么回事 / 介绍 / 说说 / 讲一下）
    //    一律不放 —— 判据是 q.indexOf(键) !== -1，泛词会劫持带主题的提问：
    //    「坑道爆破怎么回事」曾被映射到「背景」，精确条目「坑道爆破」永远轮不到。
    //    「什么时候 / 在哪里」经实测【有得有失】，故意保留，别当成漏删。
    const mapping: Record<string, string> = {
      '什么是松山战役': '松山战役', '怎么打的': '关键战斗',
      '有哪些英雄': '英雄', '谁是指挥官': '指挥官',
      '打了多久': '多久', '什么时候': '时间', '在哪里': '地点',
      '为什么重要': '意义', '有什么意义': '意义', '有多少人': '兵力',
      '伤亡': '伤亡', '死了多少人': '伤亡'
    };
    const keys = Object.keys(mapping);
    for (let i = 0; i < keys.length; i++) {
      if (q.indexOf(keys[i]) !== -1) {
        const matched: string = mapping[keys[i]];
        const localAns: string = this.knowledge.search(matched);
        this.reportKnowledgeHit(matched, localAns);
        return localAns;
      }
    }
    const ans: string = await this.knowledge.searchWithModel(q);
    this.reportKnowledgeHit(q, ans);
    return ans;
  }

  // ==================== 多问题连发拆分 ====================

  /** 返回 text 在 pos 处命中的疑问词长度，未命中返回 0（长词优先） */
  private matchMarkerLength(text: string, pos: number): number {
    for (let m = 0; m < QUESTION_MARKERS.length; m++) {
      const w: string = QUESTION_MARKERS[m];
      if (text.substring(pos, pos + w.length) === w) return w.length;
    }
    return 0;
  }

  /** 扫描全文，返回所有疑问词的起始下标（长词优先，跳过已匹配部分） */
  private markerPositions(text: string): number[] {
    const positions: number[] = [];
    let i: number = 0;
    while (i < text.length) {
      const len: number = this.matchMarkerLength(text, i);
      if (len > 0) {
        positions.push(i);
        i += len;
      } else {
        i++;
      }
    }
    return positions;
  }

  /** 在 [from, to) 窗口内找最靠前的切点字符，返回「切点后一位」下标；找不到返回 -1 */
  private nearestAnchor(text: string, from: number, to: number, anchors: string[]): number {
    for (let i = from; i < to; i++) {
      if (anchors.indexOf(text.charAt(i)) !== -1) return i + 1;
    }
    return -1;
  }

  /**
   * 定位切点。先找第一个疑问词，取其结束位置到第二个疑问词开始位置之间的窗口，
   * 窗口内取最靠前的切点字符：先高优先级「的了吗呢吧？。！」，都没有再用低优先级「，、；」。
   * 返回 -1 表示窗口内无切点，无法安全拆分。
   */
  private findSplitIndex(text: string): number {
    const positions: number[] = this.markerPositions(text);
    if (positions.length < 2) return -1;
    const firstStart: number = positions[0];
    const firstEnd: number = firstStart + this.matchMarkerLength(text, firstStart);
    const secondStart: number = positions[1];
    if (firstEnd >= secondStart) return -1;
    let cut: number = this.nearestAnchor(text, firstEnd, secondStart, SPLIT_ANCHORS_HIGH);
    if (cut < 0) cut = this.nearestAnchor(text, firstEnd, secondStart, SPLIT_ANCHORS_LOW);
    return cut;
  }

  /**
   * 检测并拆分连发的多个问题。
   * 返回长度 >= 2 的数组 = 成功拆出多个子问题；返回空数组 = 单问题或无法拆分。
   */
  private splitMultiQuestion(text: string): string[] {
    const parts: string[] = [];
    let rest: string = text.trim();
    while (parts.length < MAX_SUB_QUESTIONS && rest.length > 0) {
      if (this.markerPositions(rest).length < 2) {
        parts.push(rest);
        break;
      }
      const cut: number = this.findSplitIndex(rest);
      if (cut <= 0 || cut >= rest.length) {
        parts.push(rest);
        break;
      }
      parts.push(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    const valid: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length >= 2) valid.push(parts[i]);
    }
    return valid.length >= 2 ? valid : [];
  }

  /**
   * 逐个子问题本地检索。全部命中才返回「换行拼接」的结果；
   * 任一条未命中就返回 ''，由调用方回退整句，避免给出残缺答案。
   */
  private async answerMultiple(parts: string[]): Promise<string> {
    const answers: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const a: string = await this.searchKnowledge(parts[i]);
      if (a === '') {
        console.info('[KB_MULTI] 子问题未命中，回退整句: ' + parts[i]);
        return '';
      }
      answers.push(a);
    }
    return answers.join('\n\n');
  }

  /**
   * 云端兜底：附带本地相关上下文调用远程模型。
   * 两条失败路径都返回本地安全话术，绝不把技术错误或未校验的生成内容透给用户：
   *   路径1 callAI 抛异常（断网/超时）→ OFFLINE_REPLY
   *   路径2 callAI 成功但把松山错置到缅甸/缅北 → OUT_OF_SCOPE_REPLY
   */
  private async askCloud(query: string): Promise<string> {
    // ===== A3 路由预判：先判路，再干活 =====
    // 放在函数最顶部（而不是 try 之前）—— 判为端侧时，下面的本地上下文检索
    // 与记忆注入都不必做，直接返回。
    const netState: NetworkState = this.netProbe.snapshot(
      this.routerStats.linkFeedback(), Date.now());
    const batState: BatteryState = {
      soc: batteryInfo.batterySOC,
      charging: batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE
    };
    const decision: RouteDecision = route(
      TaskType.QA_CLOUD, netState, batState, this.routerStats.statsOf(TaskType.QA_CLOUD));

    if (decision.target === RouteTarget.DEVICE) {
      // 断网/降级：不发起请求，直接返回离线话术 —— 省掉 15s connectTimeout 白等
      this.routerStats.recordDecision(TaskType.QA_CLOUD, decision, netState.tier, true, 0);
      console.info('[A3] QA 预判端侧: ' + decision.reason);
      return OFFLINE_REPLY;
    }

    // ===== 以下为原逻辑，除统计埋点外一行不改 =====
    const context = this.knowledge.getRelevantContext(query);
    let fullPrompt = query;
    if (context !== '') fullPrompt = `请结合以下松山战役知识，回答用户问题：\n${context}\n\n用户问题：${query}`;
    const memCtx: string = this.memory.buildInjection(
      this.memory.getCurrentSpot(), this.adjacentSpotKeys(), query, MEMORY_QUANTITY);
    let text: string = '';
    const t0: number = Date.now();
    try {
      text = await this.aiService.callAI(
        fullPrompt, this.effectiveGrade(), this.conversationHistory, memCtx);
    } catch (err) {
      const elapsed: number = Date.now() - t0;
      this.routerStats.markAttempt(TaskType.QA_CLOUD, elapsed, false);
      this.routerStats.recordDecision(TaskType.QA_CLOUD, decision, netState.tier, false, elapsed);
      // 路径1：只留日志，不给用户看 Operation timeout 这类技术细节
      console.error('[KB_GUARD] 云端调用失败: ' + (err as Error).message);
      return OFFLINE_REPLY;
    }

    // ⚠️ 网络调用【本身】成功了 —— 立刻记成功，且【必须】在下面的史实护栏之前。
    //    护栏拦的是「内容越界」，不是「网络不通」；把它记成失败会污染链路反馈层，
    //    3 次幻觉就能把 App 误判成断网。反馈层测的是【可达性】，不是内容质量。
    const elapsed2: number = Date.now() - t0;
    this.routerStats.markAttempt(TaskType.QA_CLOUD, elapsed2, true);
    this.routerStats.recordDecision(TaskType.QA_CLOUD, decision, netState.tier, true, elapsed2);

    // 路径2：调用成功但史实越界，整条丢弃
    if (this.hasGeoHallucination(text)) {
      console.error('[KB_GUARD] 云端回答疑似史实错误，已拦截: ' + text);
      return OUT_OF_SCOPE_REPLY;
    }
    return text;
  }

  /**
   * 史实护栏：判断云端回答是否把松山错置到缅甸/缅北。
   * 判定依据是「松山」与「缅北/缅甸」的字面距离：某个「松山」之后 12 字内、
   * 或之前 4 字内出现「缅北」「缅甸」即判违规。
   * 用距离而非同句共现，是为了不误伤知识库里正确的「滇缅公路」
   * 「滇西缅北大反攻」「支援在缅甸作战的盟军」等表述。
   */
  private hasGeoHallucination(text: string): boolean {
    let from: number = 0;
    while (true) {
      const idx: number = text.indexOf('松山', from);
      if (idx === -1) break;
      from = idx + 2;
      const tail: string = text.substring(idx + 2, idx + 14);
      if (tail.indexOf('缅北') !== -1 || tail.indexOf('缅甸') !== -1) return true;
      const head: string = text.substring(Math.max(0, idx - 4), idx);
      if (head.indexOf('缅北') !== -1 || head.indexOf('缅甸') !== -1) return true;
    }
    return false;
  }

  /**
   * 长按气泡弹出的菜单。内联渲染而不是 bindPopup：
   * bindPopup 的 @Builder 在 selectingMsgId 变化时不一定重跑，切不到第二形态。
   * AI 回答和用户提问共用：复制恒有；朗读按钮对所有有文本的消息显示。
   */
  @Builder
  bubbleMenu(msg: ChatMessage) {
    Column() {
      Row() {
        Row() {
          Image($rawfile('icon_copy.svg')).width(18).height(18).fillColor('#FFD700')
          Text('复制').fontSize(12).fontColor('#FFE9A8').margin({ left: 6 })
        }
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => { this.copyTextToClipboard(msg.text); this.closeBubbleMenu(); })

        if (msg.text !== '') {
          Row() {
            Image($rawfile('icon_mic.svg')).width(18).height(18).fillColor('#FFD700')
            Text('朗读').fontSize(12).fontColor('#FFE9A8').margin({ left: 6 })
          }
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .onClick(() => { this.playAudio(msg); this.closeBubbleMenu(); })
        }
      }

      // 进入选取文字后就收起这一行，菜单只留横向的动作按钮
      if (this.selectingMsgId !== msg.id) {
        Divider().strokeWidth(1).color('rgba(255,215,0,0.25)')
        Row() {
          Image($rawfile('icon_select.svg')).width(18).height(18).fillColor('#FFD700')
          Text('选取文字').fontSize(12).fontColor('#FFE9A8').margin({ left: 6 })
        }
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => { this.startSelecting(msg); })
      }
    }
    .backgroundColor('#2A0000')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,215,0,0.45)' })
    .padding(6)
    .margin({ top: 6 })
  }

  /**
   * 这条消息是不是列表里最新的一条内容（欢迎语除外）。
   * 复制 / 重新生成 / 朗读 三个快捷按钮只挂在最新气泡上，旧气泡走长按菜单。
   */
  private isLatestAnswer(msg: ChatMessage): boolean {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const m: ChatMessage = this.messages[i];
      if (m.id === 0) continue;                 // 欢迎语不算
      return m.type === 0 && m.id === msg.id;
    }
    return false;
  }

  private closeBubbleMenu(): void {
    this.bubbleMenuId = 0;
    this.selectingMsgId = 0;
  }

  /**
   * 进入选取文字模式：菜单收起「选取文字」那一行，只留横向动作按钮；
   * 同时给这条 Text 打开 copyOption(LocalDevice) 允许拖拽选词。
   */
  private startSelecting(msg: ChatMessage): void {
    this.selectingMsgId = msg.id;
    this.bubbleMenuId = msg.id;
  }

  /**
   * 这条 AI 回答前面的用户提问文本；没有前置提问则返回空串。
   * 兼作「能否重新生成」的判定 —— 不依赖持久化字段，重开旧会话也成立。
   */
  private precedingQuestion(msg: ChatMessage): string {
    for (let i = 1; i < this.messages.length; i++) {
      if (this.messages[i].id === msg.id) {
        const prev: ChatMessage = this.messages[i - 1];
        return prev.type === 1 ? prev.text : '';
      }
    }
    return '';
  }

  private findMessageById(messageId: number): ChatMessage | null {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) return this.messages[i];
    }
    return null;
  }

  /**
   * 回答管线。sendMessage 与 regenerateAnswer 共用，避免两处逻辑漂移。
   * forceCloud = true 时跳过本地知识库直接问云端 ——「重新生成」用它：
   * 知识库是确定性检索（searchKnowledge 的 keyword 分支、离线的 searchWithModel），
   * 重跑同一问题只会得到同一个答案，必须绕开才谈得上「换一个」。
   */
  private async generateReply(query: string, forceCloud: boolean): Promise<string> {
    let reply: string = '';
    let answeredLocally: boolean = false;

    if (!forceCloud) {
      // ===== 临时调试：真机打印候选集分数，测试后删除 =====
      console.info('[KB_DEBUG] ' + query + '\n' + this.knowledge.debugRank(query, 5));
      // 先判断是否连发了多个问题
      const parts: string[] = this.splitMultiQuestion(query);

      if (parts.length >= 2) {
        // 临时调试：真机打印拆句结果，测试后删除
        console.info('[KB_MULTI] 拆出 ' + parts.length + ' 个子问题: ' + parts.join(' | '));
        reply = await this.answerMultiple(parts);
        answeredLocally = reply !== '';
        if (answeredLocally) {
          // 多问题全部命中：只补一次「思考中」延时，不逐段等待
          await new Promise<void>(resolve => setTimeout(resolve, 2000));
        }
      }

      if (!answeredLocally) {
        // 单问题，或多问题未能全部命中：回退整句，走原有逻辑
        const knowledgeResult: string = await this.searchKnowledge(query);
        if (knowledgeResult !== '') {
          await new Promise<void>(resolve => setTimeout(resolve, 2000));
          reply = knowledgeResult;
          answeredLocally = true;
          // 提示：看起来是多问题但只答了一条。若嫌吵可删掉下面这一行
          if (parts.length >= 2) reply = reply + MULTI_QUESTION_HINT;
        }
      }
    }

    // 未命中本地（或强制走云端）：问模型
    if (!answeredLocally) reply = await this.askCloud(query);

    if (answeredLocally && (this.effectiveGrade() === '小学' || this.effectiveGrade() === '中学')) {
      try { reply = await this.simplifyForGrade(reply, this.effectiveGrade()); } catch (e) { }
    }
    return reply;
  }

  /**
   * 把回答文本灌进一条消息：音频、是否知识库内容、猜你想问。
   * 原地填充（而不是返回新对象），这样「首发」和「重新生成」能共用同一段逻辑。
   * 返回「猜你想问」条数，由调用方决定何时逐个弹出。
   */
  private fillAnswerMessage(target: ChatMessage, reply: string, query: string): number {
    target.text = reply;
    target.isKnowledge = !this.isIgnoredText(reply);
    target.isThinking = false;
    let sugs: string[] = [];
    // 「猜你想问」：仅在拿到真实回答时生成，兜底话术不生成
    if (reply !== '' && reply !== OFFLINE_REPLY && reply !== OUT_OF_SCOPE_REPLY) {
      sugs = this.buildSuggestions(query, reply);
    }
    if (sugs.length >= 2) {
      this.clearOldSuggestions();
      target.suggestions = sugs;
      this.suggestShown = 0;
    } else {
      target.suggestions = [];
    }
    return target.suggestions.length;
  }

  /** 「猜你想问」chips 逐个弹出 */
  private revealSuggestions(count: number): void {
    for (let i = 0; i < count; i++) {
      setTimeout(() => { this.suggestShown = i + 1; }, 320 + i * 170);
    }
  }

  /**
   * 重新生成某条回答：原地替换内容，不新增用户消息。
   * 强制走云端 —— 见 generateReply 的说明。
   */
  private async regenerateAnswer(msgId: number): Promise<void> {
    if (this.regeneratingId !== 0) {
      promptAction.showToast({ message: '正在重新生成，请稍候' });
      return;
    }
    const msg: ChatMessage | null = this.findMessageById(msgId);
    if (msg === null) return;
    const query: string = this.precedingQuestion(msg);
    if (query === '') return;

    // 记下发起时的会话：生成期间用户可能切走，回来后结果不能落到别的会话上
    const sessionAtStart: number = this.currentSessionId;
    this.regeneratingId = msgId;
    const oldText: string = msg.text;
    const oldAudio: string = msg.audioFile;
    const oldKnowledge: boolean = msg.isKnowledge;
    const oldSugs: string[] = msg.suggestions;
    // 清空原文，而不是写占位串：气泡的渲染条件是 msg.text !== ''，
    // 清空后旧回答整块消失，只剩下面的「正在思考...」转圈。
    // 若写占位串，就会同时出现气泡里的占位文字 + 转圈 +「正在思考...」，三重重叠。
    msg.text = '';
    msg.isThinking = true;
    this.messages = this.messages.slice();

    // 裁掉上一轮的回答：否则云端会看到自己刚才那份，多半照着改写而不是重答
    if (this.conversationHistory.length > 0 &&
      this.conversationHistory[this.conversationHistory.length - 1].role === 'assistant') {
      this.conversationHistory.pop();
    }

    let reply: string = '';
    try {
      reply = await this.generateReply(query, true);
    } catch (err) {
      console.error('[REGEN] 重新生成失败: ' + (err as Error).message);
      reply = '';
    }

    // 用户已切走：丢弃结果，不写任何状态
    if (this.currentSessionId !== sessionAtStart) {
      this.regeneratingId = 0;
      return;
    }
    if (reply === '') {
      // 失败：还原原回答，不让用户白等一场还丢了内容
      msg.text = oldText;
      msg.audioFile = oldAudio;
      msg.isKnowledge = oldKnowledge;
      msg.suggestions = oldSugs;
      msg.isThinking = false;
      this.messages = this.messages.slice();
      this.regeneratingId = 0;
      promptAction.showToast({ message: '重新生成失败，已保留原回答' });
      return;
    }

    try {
      const sugCount: number = this.fillAnswerMessage(msg, reply, query);
      this.messages = this.messages.slice();
      this.conversationHistory.push({ role: 'assistant', content: reply });
      this.trimHistory(5);
      this.revealSuggestions(sugCount);
      if (this.voiceEnabled) this.playAudio(msg);
      await this.saveCurrentSession();
    } finally {
      // 无论中途抛什么，都必须解锁，否则按钮从此点不动
      this.regeneratingId = 0;
    }
  }

  /**
   * @param channel 入口通道。默认 TEXT —— 6 个文字调用点（快捷键 / onSubmit / 发送按钮）
   *                一个字都不用改。语音、扫码两处显式传参。
   *                用参数而非「先置字段再读」：不需要在末尾复位，杜绝遗漏。
   */
  async sendMessage(channel: EntryChannel = EntryChannel.TEXT): Promise<void> {
    // 仅作观测（入口收敛统计）；下一次调用必然被覆盖，无残留
    this.lastEntryChannel = channel;
    const trimmedText = this.inputText.trim();
    if (trimmedText === '') return;
    // 必须在下面 append 之前取样：append 之后 messages 里就有 type === 1 了
    const isFirstUserMsg: boolean = !this.hasUserMessage();
    // 用户主动提问 = 要跟到最新，恢复此前被手动上翻关掉的自动跟随
    this.autoScrollEnabled = true;
    const userMsg = new ChatMessage(Date.now(), 1, trimmedText);
    this.messages = this.messages.concat([userMsg]);
    // 用户消息一进列表就落盘：否则「思考中」的 2 秒里侧边栏还是空的。
    // 首条用户消息直接用「问题前 20 字」当标题，AI 总结回来后再升级。
    await this.saveCurrentSession(isFirstUserMsg ? this.fallbackTitle(trimmedText) : '');
    // 记下目标 id，等本轮问答结束、模型空闲后再用它跑总结（不能用 currentSessionId，中途可能切走）
    const titleTargetId: number = isFirstUserMsg ? this.currentSessionId : 0;
    const query = trimmedText;
    this.inputText = '';

    const thinkingId = Date.now() + 999;
    const thinkingMsg = new ChatMessage(thinkingId, 0, '小智正在思考......');
    thinkingMsg.isThinking = true;
    this.messages = this.messages.concat([thinkingMsg]);

    this.conversationHistory.push({ role: 'user', content: query });

    const reply: string = await this.generateReply(query, false);

    this.removeMessageById(thinkingId);
    this.conversationHistory.push({ role: 'assistant', content: reply });
    this.trimHistory(5);
    // 落一条长期记忆 —— 本地 / 云端 / 降级三条链路都落：
    // 记忆记的是「学生问过什么」，与答案来自哪条链路无关。
    await this.memory.record(this.context, this.memory.getCurrentSpot(), query, reply);

    const agentMsg = new ChatMessage(Date.now() + 1, 0, '');
    const sugCount: number = this.fillAnswerMessage(agentMsg, reply, query);
    this.messages = this.messages.concat([agentMsg]);
    this.revealSuggestions(sugCount);
    if (this.voiceEnabled) this.playAudio(agentMsg);
    // 回答落地后立刻落盘，否则侧边栏读到的还是上一次保存的快照
    await this.saveCurrentSession();
    // 本轮问答的模型调用（askCloud / simplifyForGrade）至此全部 await 结束，模型已空闲，
    // 此时才跑标题总结，不和用户正在等的回答并发
    if (titleTargetId !== 0) this.applyAutoTitle(titleTargetId, trimmedText);
  }

  private removeMessageById(messageId: number): void {
    const newMessages: ChatMessage[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id !== messageId) newMessages.push(this.messages[i]);
    }
    this.messages = newMessages;
  }

  // 是否处于新对话（仅一条 id 为 0 的欢迎消息，或为空）
  private isNewChat(): boolean {
    if (this.messages.length === 0) return true;
    return this.messages.length === 1 && this.messages[0].id === 0;
  }

  /**
   * 从知识库近邻条目生成「猜你想问」。
   * 只调用 Knowledge 已有的 public rankCandidates，不修改其检索逻辑。
   */
  private buildSuggestions(query: string, currentAnswer: string): string[] {
    if (query.trim() === '') return [];
    const hits: KnowledgeHit[] = this.knowledge.rankCandidates(query, 10);
    const out: string[] = [];
    // 第一轮：只要 FAQ —— 它的 question 本身就是完整问句，最适合当引导语
    for (let i = 0; i < hits.length && out.length < 3; i++) {
      const h: KnowledgeHit = hits[i];
      if (h.id.charAt(0) !== 'F') continue;
      if (h.score < 0.12) continue;
      if (h.answer === currentAnswer) continue;
      if (h.question === query) continue;
      out.push(h.question);
    }
    // 第二轮：不够 3 条就用 data 条目的主题名补
    for (let i = 0; i < hits.length && out.length < 3; i++) {
      const h: KnowledgeHit = hits[i];
      if (h.id.charAt(0) === 'F') continue;
      if (h.score < 0.12) continue;
      if (h.answer === currentAnswer) continue;
      if (out.indexOf(h.question) !== -1) continue;
      out.push(h.question);
    }
    return out;
  }

  /** 清掉所有历史消息上的建议，保证聊天区只显示最新一组 */
  private clearOldSuggestions(): void {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].suggestions.length > 0) {
        this.messages[i].suggestions = [];
      }
    }
  }

  private isIgnoredText(text: string): boolean { return text.length < 20 || IGNORED_PATTERNS.some(p => text.indexOf(p) !== -1); }
  private normalizeText(str: string): string { return str.replace(/[，。；！？、：；“”‘’（）《》【】\s]/g, ''); }
  private trimHistory(maxRounds: number): void {
    const maxMessages = maxRounds * 2;
    while (this.conversationHistory.length > maxMessages) this.conversationHistory.shift();
  }

  private async simplifyForGrade(text: string, grade: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const instruction = grade === '小学'
        ? '请将以下历史讲解内容用小学生能听懂的语言重新讲述，要求句子短、用词简单、生动有趣。'
        : '请将以下历史讲解内容用中学生能理解的语言重新讲述，要求清晰有条理，适当解释专业名词。';
      const messages: AIMessage[] = [
        { role: 'system', content: instruction },
        { role: 'user', content: text }
      ];
      const requestBody = JSON.stringify({ model: 'Qwen/Qwen2.5-7B-Instruct', messages: messages, temperature: 0.7, max_tokens: 500 });
      const response = await httpRequest.request(
        this.aiService.aiUrl,
        {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.aiService.aiKey}` },
          extraData: requestBody,
          connectTimeout: 10000, readTimeout: 20000
        });
      if (response.responseCode !== 200) throw new Error('简化失败');
      let resultStr = '';
      if (typeof response.result === 'string') {
        resultStr = response.result;
      } else if (response.result instanceof ArrayBuffer) {
        resultStr = buffer.from(response.result).toString('utf-8');
      }
      const jsonObj: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
      const choices: Array<Record<string, Object>> = jsonObj['choices'] as Array<Record<string, Object>>;
      if (choices && choices.length > 0) {
        const msg: Record<string, Object> = choices[0]['message'] as Record<string, Object>;
        return (msg['content'] as string).trim();
      }
      throw new Error('返回格式异常');
    } finally { httpRequest.destroy(); }
  }

  // ==================== 路线规划与报告 ====================
  /**
   * 按用户隔离的 key 后缀：登录用户用 username，未登录/游客用 guest。
   * 不用 userKeyId —— 管理员的 id 是 0，会和游客的 0 撞车，username 唯一。
   */
  private userSuffix(): string {
    return this.userKeyName !== '' ? this.userKeyName : 'guest';
  }

  /** 会话列表 / 路线 / 提示标记都按账号各存一份，退出登录不再丢 */
  private sessionsKey(): string { return PREF_KEY_SESSIONS + '_' + this.userSuffix(); }
  private sessionSeqKey(): string { return PREF_KEY_SESSION_SEQ + '_' + this.userSuffix(); }
  private routeKey(): string { return PREF_KEY_ROUTE + '_' + this.userSuffix(); }
  private routeHintKey(): string { return PREF_KEY_ROUTE_HINT + '_' + this.userSuffix(); }

  /**
   * 用户信息就绪后再加载按用户隔离的数据（会话列表、路线）。
   * 冷启动、从登录页返回、管理员快捷登录都要走这里 —— 不能抢在 userKeyName 确定之前读。
   */
  private async loadUserScopedData(): Promise<void> {
    await this.loadUserInfo();
    // 知识库是随版本发布的静态数据，登录后同步一份给教师端（热门知识点以它为准）
    this.syncKnowledgeToBackend();
    await this.loadSessions();
    await this.loadRoute();
    await this.loadQuizRecord();
    await this.loadGradeChoice();
    // 记忆按用户隔离：放这里，切账号时自动重载
    await this.memory.load(this.context);
  }

  /**
   * 把 App 的整份知识库同步到教师端（后端整份替换）。
   * 教师端的「热门知识点」以 App 的知识库为准，所以它得先有这份数据，
   * 才能把上报上来的 knowledge_id 显示成可读的条目问句。
   * 每次启动只做一次；失败把标记退回去，下次页面回显还能再试。
   */
  private syncKnowledgeToBackend(): void {
    if (this.kbSynced || this.appToken === '') return;
    const items: KnowledgeEntry[] = this.knowledge.exportAll();
    if (items.length === 0) return;
    this.kbSynced = true;
    this.backend.uploadKnowledgeSync(this.appToken, JSON.stringify(items))
      .then(() => { console.info('[KB_SYNC] 知识库已同步 ' + items.length + ' 条给教师端'); })
      .catch((e: Error) => {
        this.kbSynced = false;
        console.error('同步知识库失败: ' + e.message);
      });
  }

  private gradeKeyName(): string {
    return PREF_KEY_GRADE + '_' + this.userSuffix();
  }

  /**
   * 载入学段选择。优先级：本地存的手动选择 > 注册时填的学段 > 保持当前值。
   * 本地优先很关键：用户在主页面手动切过之后，不能被注册信息每次页面回显又覆盖回去。
   */
  private async loadGradeChoice(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const saved: string = await pref.get(this.gradeKeyName(), '') as string;
      if (saved === '小学' || saved === '中学' || saved === '大学') {
        this.selectedGrade = saved;
        return;
      }
      const user = await new UserManager(this.context).getUser();
      if (user === null) return;
      const fromProfile: string = quizSpecGradeOf(user.grade_level);
      if (fromProfile !== '') this.selectedGrade = fromProfile;
    } catch (err) { console.error('加载学段失败: ' + JSON.stringify(err)); }
  }

  /** 用户手动切学段：改状态 + 落盘，下次开 App 不再重置成「小学」 */
  private async pickGrade(grade: string): Promise<void> {
    this.selectedGrade = grade;
    try {
      const pref = await this.getPrefs();
      await pref.put(this.gradeKeyName(), grade);
      await pref.flush();
    } catch (err) { console.error('保存学段失败: ' + JSON.stringify(err)); }
  }

  private async loadRoute(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      this.routeHintShown = await pref.get(this.routeHintKey(), false) as boolean;
      const raw: string = await pref.get(this.routeKey(), '') as string;
      // 先清空再按当前用户填：换账号后不能残留上一个人的路线
      this.hasRoute = false;
      this.routePlan = { intro: '', stops: [] };
      this.routeStopsVisible = 0;
      this.showRouteHint = false;
      this.showRouteView = false;
      if (raw === '') return;
      const saved = JSON.parse(raw) as SavedRoute;
      if (saved.grade === '' || saved.hours === '') return;
      this.routeGrade = saved.grade;
      this.routeHours = saved.hours;
      this.routePlan = RoutePlanner.planStops(saved.grade, saved.hours);
      // 加载已存路线：直接全量显示，不重播浮现动画
      this.routeStopsVisible = this.routePlan.stops.length;
      this.hasRoute = true;
    } catch (err) { console.error('加载路线失败: ' + JSON.stringify(err)); }
  }

  /** 记下提示气泡已经弹过（持久化，保证只弹一次） */
  private async markRouteHintShown(): Promise<void> {
    this.routeHintShown = true;
    try {
      const pref = await this.getPrefs();
      await pref.put(this.routeHintKey(), true);
      await pref.flush();
    } catch (err) { console.error('保存提示标记失败: ' + JSON.stringify(err)); }
  }

  /**
   * 关掉路线页后的提示：只弹一次、只显示 5 秒。
   * 5 秒没点到就自己收起，不给用户留下一个挡按钮的东西。
   */
  private showRouteHintOnce(): void {
    if (!this.hasRoute || this.routeHintShown) return;
    this.showRouteHint = true;
    this.markRouteHintShown();
    setTimeout(() => { this.showRouteHint = false; }, ROUTE_HINT_MS);
  }

  /**
   * 把 fullText 逐段追加进这条消息，模拟主流 AI 的流式输出。
   * 每 tick 都整体替换数组 —— 消息列表的 ForEach 键里含 text.length，
   * 换引用才会重建那一行；只改 msg.text 是不会重绘的。
   * 步长由长度算出，保证整段大约在 STREAM_TOTAL_MS 内打完。
   */
  private async streamIntoMessage(msg: ChatMessage, fullText: string): Promise<void> {
    const total: number = fullText.length;
    msg.text = '';
    this.messages = this.messages.slice();
    if (total === 0) return;
    const ticks: number = Math.max(1, Math.floor(STREAM_TOTAL_MS / STREAM_TICK_MS));
    const step: number = Math.max(1, Math.ceil(total / ticks));
    let shown: number = 0;
    while (shown < total) {
      shown = Math.min(total, shown + step);
      msg.text = fullText.substring(0, shown);
      this.messages = this.messages.slice();
      if (shown < total) {
        await new Promise<void>(resolve => setTimeout(resolve, STREAM_TICK_MS));
      }
    }
  }

  /**
   * 路线页的流式生成：站点卡片逐张浮现，全部显示完才返回。
   * 站点数 × ROUTE_STOP_REVEAL_MS 就是这段动画的时长（5 站 ≈ 1.6s，7 站 ≈ 2.2s）。
   */
  private async revealRouteStops(): Promise<void> {
    const total: number = this.routePlan.stops.length;
    this.routeStopsVisible = 0;
    for (let i = 1; i <= total; i++) {
      this.routeStopsVisible = i;
      if (i < total) {
        await new Promise<void>(resolve => setTimeout(resolve, ROUTE_STOP_REVEAL_MS));
      }
    }
  }

  /** 新建一条 AI 消息并流式写入，最后落盘 */
  private async streamNewMessage(fullText: string): Promise<void> {
    const msg = new ChatMessage(Date.now(), 0, '');
    this.messages = this.messages.concat([msg]);
    await this.streamIntoMessage(msg, fullText);
    await this.saveCurrentSession();
  }

  private async saveRoute(grade: string, hours: string): Promise<void> {
    try {
      const data: SavedRoute = { grade: grade, hours: hours };
      const pref = await this.getPrefs();
      await pref.put(this.routeKey(), JSON.stringify(data));
      await pref.flush();
    } catch (err) { console.error('保存路线失败: ' + JSON.stringify(err)); }
  }

  /**
   * 「规划路线」入口。已存过路线就直接打开上次那份，没存过才弹选择框
   * —— 解决「关掉路线页后想再看只能重新选一遍」。
   */
  private openRoutePlan(): void {
    if (this.hasRoute) {
      this.routePlan = RoutePlanner.planStops(this.routeGrade, this.routeHours);
      // 重新打开：直接全量显示，不重播浮现动画（动画只在生成那一次播）
      this.routeStopsVisible = this.routePlan.stops.length;
      this.showRouteView = true;
      this.showRouteHint = false;
      return;
    }
    this.openRoutePicker();
  }

  /** 打开选年级/时长弹窗；已存过路线就把它作为默认选中值。路线页的「重新生成」也走这里 */
  private openRoutePicker(): void {
    if (this.hasRoute) {
      this.selectedGrade = this.routeGrade;
      this.selectedHours = this.routeHours;
    }
    this.showRouteDialog = true;
  }

  /** 把「生成中」遮罩的下限补到 GENERATING_MIN_MS，然后关掉 */
  private async holdGenerating(startedAt: number): Promise<void> {
    const elapsed: number = Date.now() - startedAt;
    if (elapsed < GENERATING_MIN_MS) {
      await new Promise<void>(resolve => setTimeout(resolve, GENERATING_MIN_MS - elapsed));
    }
    this.showGenerating = false;
  }

  /** 路线站点对应的打卡点位标识；匹配不到返回空串（如「最后献花给英雄」这类无地点的条目） */
  private spotKeyOfStop(stop: RouteStop): string {
    const s: SpotEntry | null = RoutePlanner.findSpot(stop.name);
    return s !== null ? s.key : '';
  }

  /**
   * 当前点位在路线上的相邻点位（前一个 / 后一个）。
   * 供记忆调度的空间分使用 —— 相邻点位的记忆给 0.5 权重。
   * 当前点位不在路线上时返回空数组。
   */
  private adjacentSpotKeys(): string[] {
    const out: string[] = [];
    const stops: RouteStop[] = this.routePlan.stops;
    const cur: string = this.memory.getCurrentSpot();
    if (cur === '') return out;

    let idx: number = -1;
    for (let i = 0; i < stops.length; i++) {
      if (this.spotKeyOfStop(stops[i]) === cur) { idx = i; break; }
    }
    if (idx < 0) return out;

    if (idx - 1 >= 0) {
      const k: string = this.spotKeyOfStop(stops[idx - 1]);
      if (k !== '') out.push(k);
    }
    if (idx + 1 < stops.length) {
      const k: string = this.spotKeyOfStop(stops[idx + 1]);
      if (k !== '') out.push(k);
    }
    return out;
  }

  private isStopCheckedIn(stop: RouteStop): boolean {
    const k: string = this.spotKeyOfStop(stop);
    return k !== '' && this.isCheckedIn(k);
  }

  /** 本次路线已打卡的站点数 */
  private routeCheckedCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.routePlan.stops.length; i++) {
      if (this.isStopCheckedIn(this.routePlan.stops[i])) n++;
    }
    return n;
  }

  /**
   * 出题依据：打卡点位 + 这些点位的知识库内容 + 最近对话 + 最近一份研学报告。
   * 点位和知识库是主料（保证题目与 App 内讲解一致、不跑偏），对话和报告是辅料。
   */
  private buildQuizContext(): string {
    const parts: string[] = [];

    const spotKeys: string[] = [];
    for (let i = 0; i < this.checkins.length; i++) {
      const r: CheckinRecord = this.checkins[i];
      if (r.userId !== this.userKeyId) continue;
      if (spotKeys.indexOf(r.spotKey) === -1) spotKeys.push(r.spotKey);
    }

    if (spotKeys.length > 0) {
      const labels: string[] = [];
      for (let i = 0; i < spotKeys.length; i++) labels.push(RoutePlanner.labelOf(spotKeys[i]));
      parts.push('【学生已打卡的点位】' + labels.join('、'));

      let kb: string = '';
      for (let i = 0; i < spotKeys.length; i++) {
        const ctx: string = this.knowledge.getRelevantContext(RoutePlanner.labelOf(spotKeys[i]));
        if (ctx !== '') kb = kb + ctx + '\n';
      }
      if (kb !== '') parts.push('【这些点位的知识库资料】\n' + kb);
    }

    if (this.conversationHistory.length > 0) {
      const conv: string[] = [];
      for (let i = 0; i < this.conversationHistory.length; i++) {
        const h = this.conversationHistory[i];
        conv.push((h.role === 'user' ? '学生问：' : '讲解：') + h.content);
      }
      parts.push('【最近的对话】\n' + conv.join('\n'));
    }

    for (let i = this.messages.length - 1; i >= 0; i--) {
      const t: string = this.messages[i].text;
      if (t.indexOf('【研学报告】') === 0) {
        parts.push('【学生最近写的研学报告】\n' + t);
        break;
      }
    }

    return parts.length > 0 ? parts.join('\n\n') : '学生还没有打卡记录和对话，请按松山战役的通识内容出题。';
  }

  /**
   * 逐题校验并归一化题目字段。任何一题不合格就丢弃该题 ——
   * 宁可少题触发重试，也不要把错题放进试卷。
   */
  private parseQuizJson(raw: string): QuizQuestion[] {
    const arr: Array<Record<string, Object>> = extractJsonArray(raw);
    const out: QuizQuestion[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Record<string, Object> = arr[i];
      const kind: string = readStr(item, 'kind');
      const stem: string = readStr(item, 'stem');
      const answer: string = readStr(item, 'answer');
      const explain: string = readStr(item, 'explain');
      if (stem === '' || answer === '') continue;

      const optsRaw = item['options'] as Array<Object>;
      const opts: string[] = [];
      if (optsRaw !== undefined && optsRaw !== null) {
        for (let j = 0; j < optsRaw.length; j++) opts.push(String(optsRaw[j]));
      }
      const accRaw = item['accept'] as Array<Object>;
      const accept: string[] = [];
      if (accRaw !== undefined && accRaw !== null) {
        for (let j = 0; j < accRaw.length; j++) accept.push(String(accRaw[j]));
      }

      if (kind === 'single') {
        if (opts.length !== 4 || !isOneLetter(answer)) continue;
        out.push({ kind: kind, stem: stem, options: opts, answer: answer, accept: [], explain: explain });
      } else if (kind === 'multi') {
        if (opts.length < 4 || opts.length > 5) continue;
        // 统一成升序字母串，判分时才能直接做字符串相等（等价于集合相等）
        const sorted: string = sortLetters(answer);
        if (sorted.length < 2) continue;   // 多选至少两个正确答案，只有一个说明模型出错了
        out.push({ kind: kind, stem: stem, options: opts, answer: sorted, accept: [], explain: explain });
      } else if (kind === 'judge') {
        if (answer !== 'T' && answer !== 'F') continue;
        out.push({ kind: kind, stem: stem, options: [], answer: answer, accept: [], explain: explain });
      } else if (kind === 'blank') {
        out.push({ kind: kind, stem: stem, options: [], answer: answer, accept: accept, explain: explain });
      } else if (kind === 'short') {
        out.push({ kind: kind, stem: stem, options: [], answer: answer, accept: [], explain: explain });
      }
    }
    return out;
  }

  /** 客观题组的 system prompt：把本学段的题型与数量写死，减少跑偏 */
  private quizObjectiveSystemPrompt(spec: QuizSpec): string {
    let s: string =
      '你是松山战役研学的出题老师。严格只输出一个 JSON 数组，不要任何解释文字，不要 Markdown 代码围栏。' +
      '题目内容必须与松山战役史实一致，不得编造时间、数字、人名。' +
      '共输出 ' + specObjectiveCount(spec) + ' 个元素，必须严格按下面的题型与顺序输出：\n';
    if (spec.singleCount > 0) {
      s += '· 前 ' + spec.singleCount + ' 个是单选：{"kind":"single","stem":"题干","options":["A选项","B选项","C选项","D选项"],"answer":"A","explain":"一句话解析"}\n';
    }
    if (spec.multiCount > 0) {
      s += '· 接着 ' + spec.multiCount + ' 个是多选：{"kind":"multi","stem":"题干","options":["A选项","B选项","C选项","D选项"],"answer":"ABD","explain":"一句话解析"}，answer 必须按字母升序且至少两个字母\n';
    }
    if (spec.judgeCount > 0) {
      s += '· 接着 ' + spec.judgeCount + ' 个是判断：{"kind":"judge","stem":"题干","options":[],"answer":"T","explain":"一句话解析"}，answer 只能是 T 或 F\n';
    }
    if (spec.blankCount > 0) {
      s += '· 最后 ' + spec.blankCount + ' 个是填空：{"kind":"blank","stem":"题干中用____表示空格","options":[],"answer":"参考答案","accept":["其它可接受的写法1","其它可接受的写法2"],"explain":"一句话解析"}\n';
    }
    return s;
  }

  private quizShortSystemPrompt(spec: QuizSpec): string {
    return '你是松山战役研学的出题老师。严格只输出一个 JSON 数组，不要任何解释文字，不要 Markdown 代码围栏。' +
      '题目内容必须与松山战役史实一致，不得编造时间、数字、人名。' +
      '只出简答题，共 ' + spec.shortCount + ' 个元素，全部 kind 必须是 short。' +
      '格式：{"kind":"short","stem":"题干","options":[],"answer":"参考答案要点，分点写清楚","explain":"评分要点"}。';
  }

  /** 按规格挑题：每个题型分别截到规定数量。多余的丢掉，不够的由调用方判失败触发重试 */
  private pickBySpec(all: QuizQuestion[], spec: QuizSpec, subjective: boolean): QuizQuestion[] {
    const single: QuizQuestion[] = [];
    const multi: QuizQuestion[] = [];
    const judge: QuizQuestion[] = [];
    const blank: QuizQuestion[] = [];
    const short: QuizQuestion[] = [];
    for (let i = 0; i < all.length; i++) {
      const q: QuizQuestion = all[i];
      if (q.kind === 'single' && single.length < spec.singleCount) single.push(q);
      else if (q.kind === 'multi' && multi.length < spec.multiCount) multi.push(q);
      else if (q.kind === 'judge' && judge.length < spec.judgeCount) judge.push(q);
      else if (q.kind === 'blank' && blank.length < spec.blankCount) blank.push(q);
      else if (q.kind === 'short' && short.length < spec.shortCount) short.push(q);
    }
    if (subjective) return short;
    // 客观题按 单选 → 多选 → 判断 → 填空 拼，界面上题型成组、看着清楚
    return single.concat(multi).concat(judge).concat(blank);
  }

  /**
   * 出某一组题（客观题组或简答组），带格式重试。
   * needCount 是这一组要求的总题数，不够就重试；多次都不够返回空数组。
   */
  private async generateQuizGroup(spec: QuizSpec, context: string, subjective: boolean,
    needCount: number): Promise<QuizQuestion[]> {
    const system: string = subjective
      ? this.quizShortSystemPrompt(spec)
      : this.quizObjectiveSystemPrompt(spec);
    const what: string = subjective
      ? '现在输出 ' + spec.shortCount + ' 道简答题的 JSON 数组。'
      : '现在输出 ' + specObjectiveCount(spec) + ' 道客观题的 JSON 数组（题型与数量严格按上面的顺序）。';
    const user: string = '请根据下面这位学生的研学情况出题。\n\n' + context + '\n\n' + what;

    for (let attempt = 0; attempt <= QUIZ_MAX_RETRY; attempt++) {
      let raw: string = '';
      try {
        raw = await this.aiService.callQuizModel(system, user, 8000);
      } catch (err) {
        console.error('[QUIZ] 出题调用失败: ' + (err as Error).message);
      }
      if (raw !== '') {
        const picked: QuizQuestion[] = this.pickBySpec(this.parseQuizJson(raw), spec, subjective);
        if (picked.length >= needCount) return picked;
        console.warn('[QUIZ] 第 ' + (attempt + 1) + ' 次只拿到 ' + picked.length +
          ' 题（需要 ' + needCount + '），重试');
      }
    }
    return [];
  }

  /**
   * 出整份卷子：从打包进 App 的题库（rawfile/questions.json）随机抽题。
   *
   * 已不再调用 AI 出题 —— 判分仍然是「客观题本地比对 + 简答题 AI 批改」，
   * 但那与出题是两件事。题库每个题型按 QuizSpec 的配额抽取，抽不满就报错，
   * 不做部分交付（缺题的卷子算出来的分没有意义）。
   * rawfile 读取写法与 playAudio() 一致。
   */
  private async generateQuiz(): Promise<QuizQuestion[]> {
    const spec: QuizSpec = this.quizSpec;
    const want: KindWant = {
      single: spec.singleCount, multi: spec.multiCount, judge: spec.judgeCount,
      blank: spec.blankCount, short: spec.shortCount
    };

    let text: string = '';
    try {
      const ctx = getContext(this);
      const rawContent = await ctx.resourceManager.getRawFileContent('questions.json');
      text = buffer.from(rawContent.buffer as ArrayBuffer).toString('utf-8');
    } catch (err) {
      console.error('[QUIZ] 题库读取失败: ' + (err as Error).message);
      this.quizError = '题库读取失败，App 安装包可能不完整。';
      return [];
    }

    const bank: BankQuestion[] = parseQuestionBank(text);
    const result: DrawResult = drawPaper(bank, spec.grade, want);

    if (result.shortages.length > 0) {
      let detail: string = '';
      for (let i = 0; i < result.shortages.length; i++) {
        const s: BankShortage = result.shortages[i];
        detail += (detail === '' ? '' : '、') + s.kind + ' 缺 ' + (s.need - s.got) + ' 道';
      }
      console.error('[QUIZ] 题库不足（' + spec.grade + '）：' + detail);
      this.quizError = spec.grade + '题库不足：' + detail + '。';
      return [];
    }

    const out: QuizQuestion[] = [];
    for (let i = 0; i < result.questions.length; i++) {
      const q: BankQuestion = result.questions[i];
      out.push({
        kind: q.kind, stem: q.stem, options: q.options,
        answer: q.answer, accept: q.accept, explain: q.explain
      });
    }
    return out;
  }

  /**
   * 客观题本地判分，返回「拿到的原始权重」（还没折算成百分制）。
   * 「是否答对」统一走 isAnswerRight，避免判分和逐题解析两处逻辑漂移。
   */
  private gradeObjective(): number {
    const spec: QuizSpec = this.quizSpec;
    let raw: number = 0;
    for (let i = 0; i < this.quizQuestions.length; i++) {
      const q: QuizQuestion = this.quizQuestions[i];
      if (q.kind === 'short') continue;
      const mine: string = this.quizAnswers[i] === undefined ? '' : this.quizAnswers[i];
      if (this.isAnswerRight(q, mine)) raw += specWeightOf(spec, q.kind);
    }
    return raw;
  }

  /**
   * 简答题 AI 批改。一次调用把全部简答打包送去，要回每题 0-100 的得分率。
   *
   * 批改失败（断网 / 超时 / 格式跑偏）时按 QUIZ_SHORT_FALLBACK_RATIO 给基础分，
   * 而不是给 0 —— 一次服务抖动不该把学生整段简答的分抹掉。
   * graded = false 表示走了兜底，界面要如实告诉学生。
   */
  private async gradeShortAnswers(): Promise<ShortGradeResult> {
    const items: ShortGradeInput[] = [];
    for (let i = 0; i < this.quizQuestions.length; i++) {
      const q: QuizQuestion = this.quizQuestions[i];
      if (q.kind !== 'short') continue;
      const mine: string = this.quizAnswers[i] === undefined ? '' : this.quizAnswers[i];
      items.push({ index: i, stem: q.stem, reference: q.answer, mine: mine });
    }

    const fallbackPct: number = Math.round(QUIZ_SHORT_FALLBACK_RATIO * 100);
    const ratios: number[] = [];
    const gradedItems: boolean[] = [];
    for (let i = 0; i < items.length; i++) { ratios.push(fallbackPct); gradedItems.push(false); }
    const fallback: ShortGradeResult = { ratios: ratios, gradedItems: gradedItems, graded: false };
    if (items.length === 0) {
      const clean: ShortGradeResult = { ratios: [], gradedItems: [], graded: true };
      return clean;
    }

    const system: string =
      '你是松山战役研学测试的阅卷老师，根据参考答案要点给学生的简答打分。' +
      '严格只输出一个 JSON 数组，不要任何解释文字，不要 Markdown 代码围栏。' +
      '每个元素格式：{"index":题目序号,"ratio":0到100的整数,"comment":"一句话点评，指出缺了什么"}。' +
      '完全答错或空白给 0；要点答全给 100；部分正确按比例给。';

    const lines: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: ShortGradeInput = items[i];
      lines.push('题目序号 ' + it.index + '\n题干：' + it.stem +
        '\n参考答案要点：' + it.reference +
        '\n学生作答：' + (it.mine === '' ? '（未作答）' : it.mine));
    }
    const user: string = '请给下面 ' + items.length + ' 道简答题逐一打分。\n\n' + lines.join('\n\n');

    let raw: string = '';
    try {
      raw = await this.aiService.callQuizModel(system, user, 4000);
    } catch (err) {
      console.error('[QUIZ] 简答批改调用失败: ' + (err as Error).message);
      return fallback;
    }
    if (raw === '') return fallback;

    const parsed: Array<Record<string, Object>> = extractJsonArray(raw);
    let matched: number = 0;
    for (let i = 0; i < parsed.length; i++) {
      const row: Record<string, Object> = parsed[i];
      const idx: number = readNum(row, 'index');
      const ratio: number = readNum(row, 'ratio');
      if (ratio < 0 || ratio > 100) continue;
      for (let j = 0; j < items.length; j++) {
        if (items[j].index !== idx) continue;
        ratios[j] = Math.round(ratio);
        gradedItems[j] = true;
        matched++;
        break;
      }
    }
    // 一条都没对上说明整组返回不可用，整组走兜底；对上的题用 AI 的分，没对上的保留兜底分
    if (matched === 0) return fallback;
    const ok: ShortGradeResult = { ratios: ratios, gradedItems: gradedItems, graded: true };
    return ok;
  }

  /** 逐题明细，存进后端供教师端看每题对错 */
  private buildQuizDetail(shortRatios: number[], shortGradedItems: boolean[]): string {
    const rows: QuizDetailRow[] = [];
    let shortSeen: number = 0;
    for (let i = 0; i < this.quizQuestions.length; i++) {
      const q: QuizQuestion = this.quizQuestions[i];
      const mine: string = this.quizAnswers[i] === undefined ? '' : this.quizAnswers[i];
      if (q.kind === 'short') {
        const ratio: number = shortRatios[shortSeen] === undefined
          ? Math.round(QUIZ_SHORT_FALLBACK_RATIO * 100) : shortRatios[shortSeen];
        // ⚠️ 必须在 shortSeen++ 之前读，否则取到的是下一题
        const itemGraded: boolean = shortGradedItems[shortSeen] === undefined
          ? false : shortGradedItems[shortSeen];
        shortSeen++;
        rows.push({
          index: i + 1, kind: q.kind, stem: q.stem, mine: mine,
          // 未获 AI 批改的题不能记为「答对」：兜底分只是不抹零的保护，不是判定结果
          answer: q.answer, ok: itemGraded && ratio >= 60, ratio: ratio
        });
      } else {
        const ok: boolean = this.isAnswerRight(q, mine);
        rows.push({
          index: i + 1, kind: q.kind, stem: q.stem, mine: mine,
          answer: q.answer, ok: ok, ratio: ok ? 100 : 0
        });
      }
    }
    return JSON.stringify(rows);
  }

  /**
   * 点「出题测试」的入口。优先级：
   *   ① 有**进行中**的测试 → 接着答、接着计时
   *      （这是「关掉测试再开不能重置计时」的实现：截止时间戳存在进度里，
   *        恢复时按它算剩余，而不是重新给 90 分钟）
   *   ② 已考过 → 展示上次成绩（原行为）
   *   ③ 都没有 → 走一次全新出题
   *
   * resume = false 是给「重新出题」用的：强制全新卷子，并清掉旧进度。
   */
  private async openQuiz(resume: boolean): Promise<void> {
    if (!resume) {
      await this.clearQuizProgress();
    } else {
      const saved: QuizProgress | null = await this.loadQuizProgress();
      if (saved !== null) {
        this.quizGrade = saved.grade === '' ? '小学' : saved.grade;
        this.quizSpec = quizSpecOf(this.quizGrade);
        this.quizQuestions = saved.questions;
        this.quizAnswers = saved.answers;
        this.quizDeadlineMs = saved.deadlineMs;
        this.quizScore = 0;
        this.quizRanking = [];
        this.quizMe = null;
        this.quizError = '';
        this.quizRankNote = '';
        this.quizGradeNote = '';
        this.hasQuizRecord = false;
        this.showAnswerSheet = false;
        this.showQuizView = true;
        this.quizStage = 'answering';
        this.startQuizTimer();

        // 关掉测试期间时间就到了 —— 补一次自动交卷，判分链路照常走
        if (this.quizRemainSec <= 0) {
          await this.autoSubmitByTimeout();
        }
        return;
      }
    }

    // 已考过：展示上次的卷子与成绩，不重新出题（要新卷子走页面里的「重新出题」按钮）。
    // 排名每次都重新拉 —— 期间可能又有别的同学考了。
    if (this.hasQuizRecord && this.quizQuestions.length > 0) {
      this.quizError = '';
      this.quizRankNote = '';
      this.quizGradeNote = '';
      this.showQuizView = true;
      this.quizStage = 'done';
      await this.loadQuizRanking();
      return;
    }

    // 按当前学段选规格：题目数量、分值、提示词全跟着它走
    this.quizGrade = this.effectiveGrade();
    this.quizSpec = quizSpecOf(this.quizGrade);
    this.quizStage = 'generating';
    this.quizQuestions = [];
    this.quizAnswers = [];
    this.quizScore = 0;
    this.quizRanking = [];
    this.quizMe = null;
    this.quizError = '';
    this.quizRankNote = '';
    this.quizGradeNote = '';
    this.showAnswerSheet = false;
    this.showQuizView = true;

    const questions: QuizQuestion[] = await this.generateQuiz();
    // 出题期间用户可能已关掉页面，直接丢弃
    if (!this.showQuizView) return;

    if (questions.length === 0) {
      // generateQuiz 若已写明具体原因（题库不足 / 读取失败）就沿用，否则给通用兜底。
      // 题库路径下不再有「网络问题」这一说 —— 抽题是本地的。
      if (this.quizError === '') {
        this.quizError = '抽题失败：题库数据异常，请把这条信息告诉开发者。';
      }
      this.quizStage = 'done';
      return;
    }
    this.quizQuestions = questions;
    const blank: string[] = [];
    for (let i = 0; i < questions.length; i++) blank.push('');
    this.quizAnswers = blank;
    this.quizStage = 'answering';
    // 开始计时。从进入作答那一刻算 —— 前面 5 秒的导入动画不该吃学生的作答时间
    this.quizDeadlineMs = Date.now() + QUIZ_DURATION_MS;
    this.startQuizTimer();
  }

  /** 「重新出题 / 重试」：清掉上次结果与进行中的进度，强制走一次新的出题 */
  private async restartQuiz(): Promise<void> {
    this.hasQuizRecord = false;
    this.quizQuestions = [];
    this.quizAnswers = [];
    this.quizScore = 0;
    this.quizRanking = [];
    this.quizMe = null;
    await this.openQuiz(false);
  }

  /** 拉本班排名。失败原因写进 quizRankNote 显示到页面上，不再静默不渲染 */
  private async loadQuizRanking(): Promise<void> {
    if (this.appToken === '') {
      this.quizRanking = [];
      this.quizMe = null;
      this.quizRankNote = '未登录，看不到班级排名';
      return;
    }
    try {
      const raw: Record<string, Object> = await this.backend.fetchQuizRanking(this.appToken);
      this.quizRanking = parseQuizRanking(raw);
      this.quizMe = parseQuizMe(raw);
      this.quizRankNote = this.quizRanking.length === 0 ? '本班还没有成绩记录' : '';
    } catch (e) {
      const msg: string = (e as Error).message;
      console.error('拉取排名失败: ' + msg);
      this.quizRanking = [];
      this.quizMe = null;
      this.quizRankNote = '排名获取失败：' + msg;
    }
  }

  /**
   * 选中答案。单选/判断是覆盖，多选是勾选/取消（结果存成升序字母串）。
   * 必须整体替换数组 —— @State 观察不到原地改。
   */
  private pickAnswer(qIndex: number, value: string): void {
    if (qIndex < 0 || qIndex >= this.quizAnswers.length) return;
    if (qIndex >= this.quizQuestions.length) return;
    const next: string[] = this.quizAnswers.slice();
    const current: string = next[qIndex] === undefined ? '' : next[qIndex];
    if (this.quizQuestions[qIndex].kind === 'multi') {
      next[qIndex] = toggleLetter(current, value);
    } else {
      next[qIndex] = value;
    }
    this.quizAnswers = next;
  }

  /** 已作答的题数 */
  private answeredCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.quizAnswers.length; i++) {
      if (this.quizAnswers[i] !== '') n++;
    }
    return n;
  }

  /**
   * 跳到第 index 题（0 基）。答题卡点题号走这里。
   * 用 List 的 scrollToIndex —— Scroll 只能按像素偏移，各题高度不一，算偏移不可靠。
   * ScrollAlign.START 让目标题顶到可视区上方，避免停在半截。
   */
  private jumpToQuestion(index: number): void {
    this.showAnswerSheet = false;
    this.quizScroller.scrollToIndex(index, true, ScrollAlign.START);
  }

  /** 把答案代号翻成可读文本：判断 T/F → 对/错，单选多选补上选项内容，填空简答原样显示 */
  private answerText(q: QuizQuestion, value: string): string {
    if (value === '') return '未作答';
    if (q.kind === 'judge') return value === 'T' ? '对' : '错';
    if (q.kind === 'blank' || q.kind === 'short') return value;
    const parts: string[] = [];
    for (let i = 0; i < value.length; i++) {
      const idx: number = value.charCodeAt(i) - 65;
      if (idx >= 0 && idx < q.options.length) {
        parts.push(value.charAt(i) + '. ' + q.options[idx]);
      }
    }
    return parts.length > 0 ? parts.join('　') : value;
  }

  /** 某选项是否被选中。单选是多选的特例（答案串里只有一个字母），同一套判断通吃 */
  private isOptionPicked(qIndex: number, letter: string): boolean {
    const a: string = this.quizAnswers[qIndex] === undefined ? '' : this.quizAnswers[qIndex];
    return a.indexOf(letter) !== -1;
  }

  private kindLabel(kind: string): string {
    if (kind === 'single') return '单选题';
    if (kind === 'multi') return '多选题';
    if (kind === 'judge') return '判断题';
    if (kind === 'blank') return '填空题';
    return '简答题';
  }

  /** 某题折算到百分制后的分值，标在题卡右上角 */
  private questionScoreText(q: QuizQuestion): string {
    const maxW: number = specMaxWeight(this.quizSpec);
    if (maxW <= 0) return '';
    const v: number = specWeightOf(this.quizSpec, q.kind) / maxW * QUIZ_FULL_SCORE;
    const rounded: number = Math.round(v * 10) / 10;
    if (rounded === Math.floor(rounded)) return Math.floor(rounded) + ' 分';
    return rounded.toFixed(1) + ' 分';
  }

  /** 某道题是否答对（简答题不在这里判，出分后统一按 AI 得分率展示） */
  private isAnswerRight(q: QuizQuestion, mine: string): boolean {
    if (mine === '') return false;
    if (q.kind === 'multi') return sortLetters(mine) === q.answer;
    if (q.kind === 'blank') {
      const norm: string = normalizeBlank(mine);
      if (norm === '') return false;
      if (norm === normalizeBlank(q.answer)) return true;
      for (let j = 0; j < q.accept.length; j++) {
        if (norm === normalizeBlank(q.accept[j])) return true;
      }
      return false;
    }
    return mine === q.answer;
  }

  /**
   * 交卷：客观题本地判分 + 简答 AI 批改 → 折算百分制 → 上传 → 拉排名 → 存本地。
   * auto = true 表示这次是超时自动交卷（会加一条提示）。
   *
   * 防重入只靠 quizStage 这一道门：本函数在**任何 await 之前**就把阶段改成 'grading'，
   * 所以第二次进来（双击按钮，或点交卷的同一秒计时归零）必然看到非 'answering' 而直接返回。
   * 特意不再加一个布尔标志 —— 那个在万一有异常逃逸时会把交卷永久卡死。
   */
  private async submitQuiz(auto: boolean): Promise<void> {
    if (this.quizStage !== 'answering') return;
    this.stopQuizTimer();
    this.quizStage = 'grading';
    // 超时提示写在 quizRankNote：下面上传失败也往它追加，两者不会互相覆盖
    if (auto) this.quizRankNote = '时间到，已自动交卷。';
    this.quizGradeNote = '';
    const spec: QuizSpec = this.quizSpec;

    // ① 客观题本地判分，拿到的是原始权重
    let rawScore: number = this.gradeObjective();

    // ② 简答 AI 批改，按每题得分率折算成权重
    const shortResult: ShortGradeResult = await this.gradeShortAnswers();
    let shortSeen: number = 0;
    for (let i = 0; i < this.quizQuestions.length; i++) {
      if (this.quizQuestions[i].kind !== 'short') continue;
      const ratio: number = shortResult.ratios[shortSeen] === undefined
        ? Math.round(QUIZ_SHORT_FALLBACK_RATIO * 100)
        : shortResult.ratios[shortSeen];
      rawScore += spec.shortWeight * ratio / 100;
      shortSeen++;
    }
    if (shortSeen > 0 && !shortResult.graded) {
      this.quizGradeNote = '简答题本次未能自动批改，已按 '
        + Math.round(QUIZ_SHORT_FALLBACK_RATIO * 100) + '% 基础分计入。';
    }

    // ③ 权重折算成百分制
    const maxW: number = specMaxWeight(spec);
    this.quizScore = maxW > 0 ? Math.round(rawScore / maxW * QUIZ_FULL_SCORE) : 0;

    let uploadErr: string = '';
    if (this.appToken === '') {
      uploadErr = '未登录，成绩未上传';
    } else {
      try {
        await this.backend.uploadQuiz(this.appToken, this.quizGrade, this.quizScore,
          QUIZ_FULL_SCORE, this.buildQuizDetail(shortResult.ratios, shortResult.gradedItems));
      } catch (e) {
        uploadErr = '成绩上传失败：' + (e as Error).message;
        console.error(uploadErr);
      }
    }

    await this.saveQuizRecord();
    await this.loadQuizRanking();
    // 上传失败优先显示 —— 排名拉不到往往就是因为它
    if (uploadErr !== '') {
      this.quizRankNote = this.quizRankNote === '' ? uploadErr : uploadErr + '；' + this.quizRankNote;
    }
    // 交了就不再是「进行中」，否则下次点「出题测试」会把这份卷子又恢复出来
    await this.clearQuizProgress();
    this.quizStage = 'done';
  }

  private quizKeyName(): string {
    return PREF_KEY_QUIZ + '_' + this.userSuffix();
  }

  /** 载入上次成绩。按用户隔离，换账号不能留着上一个人的卷子 */
  private async loadQuizRecord(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const raw: string = await pref.get(this.quizKeyName(), '') as string;
      this.hasQuizRecord = false;
      this.quizQuestions = [];
      this.quizAnswers = [];
      this.quizScore = 0;
      this.quizRanking = [];
      this.quizMe = null;
      this.quizStage = 'generating';
      this.quizRankNote = '';
      if (raw === '') return;
      const rec = JSON.parse(raw) as QuizRecord;
      if (rec.questions.length === 0) return;
      this.quizQuestions = rec.questions;
      this.quizAnswers = rec.answers;
      this.quizScore = rec.score;
      // 学段规格要跟着卷子一起还原，否则分值/题数显示会回到小学的
      this.quizGrade = rec.grade === '' ? '小学' : rec.grade;
      this.quizSpec = quizSpecOf(this.quizGrade);
      this.hasQuizRecord = true;
      this.quizStage = 'done';
    } catch (err) { console.error('加载上次成绩失败: ' + JSON.stringify(err)); }
  }

  private async saveQuizRecord(): Promise<void> {
    try {
      const rec: QuizRecord = {
        grade: this.quizGrade, score: this.quizScore, total: QUIZ_FULL_SCORE,
        questions: this.quizQuestions, answers: this.quizAnswers
      };
      const pref = await this.getPrefs();
      await pref.put(this.quizKeyName(), JSON.stringify(rec));
      await pref.flush();
      this.hasQuizRecord = true;
    } catch (err) { console.error('保存成绩失败: ' + JSON.stringify(err)); }
  }

  /* ---------- 进行中的测试：持久化 ---------- */

  private quizProgressKey(): string {
    return PREF_KEY_QUIZ_PROGRESS + '_' + this.userSuffix();
  }

  /**
   * 把进行中的测试落盘：题目 + 已填答案 + 截止时间戳。
   * 写盘时机 = 点 X 关闭时，以及作答中每 QUIZ_AUTOSAVE_TICKS 秒。
   * 后者是为了兜住「不点 X 直接杀掉 App」—— 那种情况最多丢十秒的作答。
   */
  private async saveQuizProgress(): Promise<void> {
    if (this.quizStage !== 'answering' || this.quizQuestions.length === 0) return;
    try {
      const rec: QuizProgress = {
        grade: this.quizGrade,
        questions: this.quizQuestions,
        answers: this.quizAnswers,
        deadlineMs: this.quizDeadlineMs
      };
      const pref = await this.getPrefs();
      await pref.put(this.quizProgressKey(), JSON.stringify(rec));
      await pref.flush();
    } catch (err) { console.error('保存测试进度失败: ' + JSON.stringify(err)); }
  }

  /** 读回进行中的测试。字段缺失或解析失败一律当「没有」，不要让它把状态带脏 */
  private async loadQuizProgress(): Promise<QuizProgress | null> {
    try {
      const pref = await this.getPrefs();
      const raw: string = await pref.get(this.quizProgressKey(), '') as string;
      if (raw === '') return null;
      const rec = JSON.parse(raw) as QuizProgress;
      if (rec.questions === undefined || rec.questions.length === 0) return null;
      if (rec.answers === undefined || rec.deadlineMs === undefined) return null;
      return rec;
    } catch (err) {
      console.error('读取测试进度失败: ' + JSON.stringify(err));
      return null;
    }
  }

  private async clearQuizProgress(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      await pref.delete(this.quizProgressKey());
      await pref.flush();
    } catch (err) { console.error('清除测试进度失败: ' + JSON.stringify(err)); }
  }

  /* ---------- 倒计时 ---------- */

  /**
   * 启动倒计时。
   * **按墙上时钟算剩余，不做 tick 累加** —— 鸿蒙在息屏/切后台时会挂起 setInterval，
   * 累加计数在那段时间根本不动，学生锁屏十分钟回来会发现时间几乎没走。
   * 用绝对时间戳算，回来自动补正。
   */
  private startQuizTimer(): void {
    this.stopQuizTimer();
    this.quizTickCount = 0;
    this.updateQuizRemain();
    this.quizTimerId = setInterval(() => { this.tickQuizTimer(); }, 1000);
  }

  private stopQuizTimer(): void {
    if (this.quizTimerId !== -1) {
      clearInterval(this.quizTimerId);
      this.quizTimerId = -1;
    }
  }

  private updateQuizRemain(): void {
    const left: number = this.quizDeadlineMs - Date.now();
    this.quizRemainSec = left > 0 ? Math.ceil(left / 1000) : 0;
  }

  private tickQuizTimer(): void {
    this.updateQuizRemain();
    if (this.quizRemainSec <= 0) {
      this.stopQuizTimer();
      this.autoSubmitByTimeout();
      return;
    }
    this.quizTickCount++;
    if (this.quizTickCount >= QUIZ_AUTOSAVE_TICKS) {
      this.quizTickCount = 0;
      this.saveQuizProgress();
    }
  }

  /** 剩余时间的显示文本。到 0 之后会立刻交卷、通常看不到，但兜一下 */
  private remainText(): string {
    const s: number = this.quizRemainSec;
    const m: number = Math.floor(s / 60);
    const sec: number = s % 60;
    return '剩余 ' + m + ':' + (sec < 10 ? '0' : '') + sec;
  }

  /**
   * 超时自动交卷。与手动交卷共用 submitQuiz()，重入由那里的阶段门挡住，
   * 所以「点交卷的同一秒计时归零」不会上传两遍。
   */
  private async autoSubmitByTimeout(): Promise<void> {
    await this.submitQuiz(true);
  }

  /**
   * 「确定」后：存路线 + 弹全屏页 + 往对话塞文字摘要。
   * 全程盖 5 秒「小智生成中」遮罩 —— 内容是本地即时生成的，不补下限会毫无过程感。
   */
  private async executeRoutePlan(): Promise<void> {
    this.showGenerating = true;
    this.generatingText = '小智正在规划路线…';
    const t0: number = Date.now();
    let planText: string = '';
    try {
      // 「确定」即视为覆盖：旧路线被这次的选择替换掉，不需要用户先删
      this.routeGrade = this.selectedGrade;
      this.routeHours = this.selectedHours;
      this.routePlan = RoutePlanner.planStops(this.routeGrade, this.routeHours);
      this.hasRoute = true;
      await this.saveRoute(this.routeGrade, this.routeHours);
      // 同步给教师端（未登录时内部直接 return）
      this.uploadRoute();
      // 对话里的文字摘要仍走 plan() 原文（同一份数据源）
      planText = RoutePlanner.plan(this.routeGrade, this.routeHours);
    } finally {
      await this.holdGenerating(t0);
    }
    // 遮罩收起后：亮出路线页，站点逐张浮现（这就是"路线页也在流式生成"）；
    // 文字摘要同时在页面背后流式写完，用户关掉路线页时它已经打完了。
    this.showRouteView = true;
    this.showRouteHint = false;
    const textTask: Promise<void> = this.streamNewMessage(planText);
    await this.revealRouteStops();
    await textTask;
  }

  /** 报告生成的等待遮罩包装；正文见 buildReport()。遮罩收起后再流式写进对话 */
  private async handleGenerateReport(): Promise<void> {
    this.showGenerating = true;
    this.generatingText = '小智正在生成研学报告…';
    const t0: number = Date.now();
    let reportText: string = '';
    try {
      reportText = await this.buildReport();
    } catch (err) {
      console.error('生成报告失败: ' + (err as Error).message);
    } finally {
      // 中途抛异常也必须收起遮罩，否则界面被永久盖住
      await this.holdGenerating(t0);
    }
    if (reportText === '') {
      promptAction.showToast({ message: '报告生成失败，请重试' });
      return;
    }
    await this.streamNewMessage(reportText);
  }

  /** 报告的实际生成逻辑（原正文逐行未动，只是把文本返回给调用方去流式输出） */
  private async buildReport(): Promise<string> {
    const startTime: number = Date.now();
    const keyPoints: string[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      const msg = this.messages[i];
      if (msg.type !== 0 || !msg.isKnowledge || msg.text === '') continue;
      if (msg.text.length < 20) continue;
      if (this.isIgnoredText(msg.text)) continue;
      const punctuationCount = (msg.text.match(/[。；！？;!?]/g) || []).length;
      if (punctuationCount < 1) continue;
      const sentences = msg.text.split(/[。；！？；;!?]/);
      let core = '';
      for (let k = 0; k < sentences.length && k < 2; k++) {
        const candidate = sentences[k].trim();
        if (candidate.length >= 10 && !this.isIgnoredText(candidate)) { core = candidate; break; }
      }
      if (core !== '') keyPoints.push(core);
    }
    const uniquePoints: string[] = [];
    for (let i = 0; i < keyPoints.length; i++) {
      let duplicate = false;
      const normI = this.normalizeText(keyPoints[i]);
      for (let j = 0; j < uniquePoints.length; j++) {
        if (normI === this.normalizeText(uniquePoints[j])) { duplicate = true; break; }
      }
      if (!duplicate) uniquePoints.push(keyPoints[i]);
    }
    let summary = '';
    const totalChars = uniquePoints.join('').length;
    if (uniquePoints.length > 5 || totalChars > 300) {
      try { summary = await this.aiService.callAIForSummary(uniquePoints.join('；')); } catch (e) { summary = uniquePoints.join('；'); }
    } else { summary = uniquePoints.join('；'); }
    if (summary.length > 500) summary = summary.substring(0, 500) + '...';

    // 兜底：仅当总结为空时使用。绝不覆盖非空结果 ——
    // 覆盖会让演示中出现的「AI 总结」实际是写死的字符串，属于成果失真。
    const EMPTY_FALLBACK_SUMMARY = '1. 松山战役发生于1944年6月4日至9月7日，历时95天\n' +
      '2. 中国远征军全歼日军守备队，打通了滇缅公路\n' +
      '3. 战役是滇西缅北反攻的关键转折点\n' +
      '4. 坑道爆破战术成功摧毁子高地日军核心堡垒\n' +
      '5. 李弥、刘栋臣等将领在战役中发挥关键作用';

    if (summary.trim() === '') {
      summary = EMPTY_FALLBACK_SUMMARY;
    }

    // 日期幻觉拦截：模型可能把「1944 年」写成「144 年」、「95 天」写成「5 天」。
    // 不替换原文（那等于伪造 AI 输出），只追加一行提示，把核对权交回学生。
    // 注：原实现还拦「错误」二字 —— 那不是幻觉特征，任何正常表述都可能命中，已移除。
    if (summary.indexOf('144年') !== -1 || /(^|[^0-9])5天/.test(summary)) {
      summary = summary + '\n\n⚠️ 以上日期表述可能有误。松山战役为 1944 年 6 月 4 日至 9 月 7 日，'
        + '历时 95 天，请以教材为准。';
    }

    const randomIndex = Math.floor(Math.random() * THINKING_QUESTIONS.length);
    const selectedQuestion = THINKING_QUESTIONS[randomIndex];
    const reportText = '【研学报告】\n【知识点总结】\n' + summary + '\n\n【思考题】\n' + selectedQuestion + '\n\n【研学结语】\n松山战役展现了中华民族不屈的意志，值得我们永远铭记。';
    const duration: number = Math.round((Date.now() - startTime) / 1000);
    this.uploadReport(reportText, duration);
    // 文本交给调用方流式写进对话，这里不再直接入列
    return reportText;
  }

  private async copyTextToClipboard(text: string): Promise<void> {
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      promptAction.showToast({ message: '已复制' });
    } catch (err) { promptAction.showToast({ message: '复制失败' }); }
  }

  private async checkScanParams(): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context, 'scan_params');
      const point: string = await pref.get('scanPoint', '') as string;
      const question: string = await pref.get('scanQuestion', '') as string;
      if (question !== '') {
        this.inputText = question;
        await pref.delete('scanQuestion');
        await pref.flush();
        this.sendMessage(EntryChannel.SCAN);
      } else if (point !== '') {
        await pref.delete('scanPoint');
        await pref.flush();
        // 清掉快路径的残留：冷启动时 EntryAbility 两条通道都写了，
        // 这里消费掉 preferences 之后要把它抹掉，否则 pendingSpot 一直占着那个值，
        // 下次扫同一个点位 setOrCreate 写入同值不产生变化，@Watch 不会触发。
        AppStorage.setOrCreate('pendingSpot', '');
        // 走统一入口：已知点位 → 打卡讲解卡片；未知 → 保留老路径拼问题
        this.handleScannedText(point, false);
      }
    } catch (e) {
      console.error('扫码参数处理失败: ' + (e as Error).message);
    }
  }

  /**
   * AppStorage 快路径的消费者（热启动）。
   * 处理完必须清空 AppStorage：否则下次扫同一个点位时 setOrCreate 写的是同值、
   * 不产生变化，@Watch 不会再触发，那个点位就永远扫不动了。
   */
  private onPendingSpotChanged(): void {
    const raw: string = this.pendingSpot;
    if (raw === '') return;
    AppStorage.setOrCreate('pendingSpot', '');
    this.handleScannedText(raw, false);
  }

  /**
   * 扫码结果统一入口。系统相机 deep link（经 scan_params 中转）、AppStorage 快路径、
   * 以及以后的相册选图都归到这里。
   * 匹配到已知点位 → 打卡讲解卡片；匹配不到 → 保留老路径（拼「请给我讲讲xxx」）。
   */
  private handleScannedText(raw: string, fromAlbum: boolean): void {
    // 两条通道可能对同一次扫码各调一次，短窗口内的同一串只认第一次
    const now: number = Date.now();
    if (raw === this.lastScanRaw && now - this.lastScanAt < 1500) return;
    this.lastScanRaw = raw;
    this.lastScanAt = now;

    const point: string = extractPointParam(raw);
    const spot: SpotEntry | null = RoutePlanner.findSpot(point !== '' ? point : raw);
    if (spot !== null) {
      this.scanSpotFlow(spot, fromAlbum);
      return;
    }
    this.inputText = '请给我讲讲' + (point !== '' ? point : raw.trim());
    this.sendMessage(EntryChannel.SCAN);
  }

  private async loadCheckins(): Promise<void> {
    try {
      const pref = await this.getPrefs();
      const raw: string = await pref.get(PREF_KEY_CHECKINS, '') as string;
      if (raw === '') return;
      this.checkins = JSON.parse(raw) as CheckinRecord[];
    } catch (err) { console.error('加载打卡记录失败: ' + JSON.stringify(err)); }
  }

  /** 当前用户在这个点位打过卡没有。游客(userKeyId === 0)只看自己的匿名记录 */
  private isCheckedIn(spotKey: string): boolean {
    if (spotKey === '') return false;
    for (let i = 0; i < this.checkins.length; i++) {
      const r: CheckinRecord = this.checkins[i];
      if (r.spotKey === spotKey && r.userId === this.userKeyId) return true;
    }
    return false;
  }

  /** 当前用户在该点位最近一次打卡时间；没打过返回 0 */
  private checkinTime(spotKey: string): number {
    for (let i = this.checkins.length - 1; i >= 0; i--) {
      const r: CheckinRecord = this.checkins[i];
      if (r.spotKey === spotKey && r.userId === this.userKeyId) return r.timestamp;
    }
    return 0;
  }

  /** 当前用户已打卡的点位数 */
  private checkedInCount(): number {
    let n: number = 0;
    const all: SpotEntry[] = RoutePlanner.allSpots();
    for (let i = 0; i < all.length; i++) {
      if (this.isCheckedIn(all[i].key)) n++;
    }
    return n;
  }

  /** 写一条打卡记录。已打过返回 false。整体替换数组 —— @State 观察不到原地改 */
  private async saveCheckin(spotKey: string, source: string): Promise<boolean> {
    // 打卡 = 到达点位。必须放在 isCheckedIn 早返回【之前】——
    // 否则「再次走到已打卡点位」时 currentSpot 不更新，记忆的空间分丢失。
    await this.memory.setCurrentSpot(this.context, spotKey);
    if (this.isCheckedIn(spotKey)) return false;
    const next: CheckinRecord[] = this.checkins.slice();
    next.push({ spotKey: spotKey, timestamp: Date.now(), userId: this.userKeyId, source: source });
    this.checkins = next;
    try {
      const pref = await this.getPrefs();
      await pref.put(PREF_KEY_CHECKINS, JSON.stringify(next));
      await pref.flush();
    } catch (err) { console.error('保存打卡记录失败: ' + JSON.stringify(err)); }
    return true;
  }

  /**
   * 消息列表 ForEach 的键。必须包含所有会原地变化的字段 —— 尤其 isCheckedIn：
   * 打卡后 text / isThinking 都不变，键里不带打卡态的话这个气泡不会重建，
   * 「确认打卡」按钮就不会变成「已打卡」。（本项目第四次踩同一个坑）
   */
  private messageKey(msg: ChatMessage): string {
    return msg.id.toString() + '_' + (msg.isThinking ? 't' : 'f') +
      '_' + msg.repairProgress.toString() + '_' + msg.suggestions.length.toString() +
      '_' + msg.text.length.toString() +
      '_' + (this.isCheckedIn(msg.spotKey) ? 'c' : 'n');
  }

  /**
   * 扫码后的点位讲解流程。刻意不复用 sendMessage：扫码不是提问，
   * 聊天里只该多一条 AI 气泡，不该有用户消息 / 猜你想问。
   * 但借用 isThinking 占位，走云端兜底时也有反馈。
   */
  private async scanSpotFlow(spot: SpotEntry, fromAlbum: boolean): Promise<void> {
    const sessionAtStart: number = this.currentSessionId;
    this.closeBubbleMenu();
    const card = new ChatMessage(Date.now() + 999, 0, '');
    card.isThinking = true;
    this.messages = this.messages.concat([card]);

    let speech: string = this.knowledge.search(spot.knowledgeQuery);
    if (speech === '') speech = await this.askCloud(spot.label);

    // 用户已切走：丢弃结果，不写任何状态
    if (this.currentSessionId !== sessionAtStart) return;
    if (speech === '') speech = '暂时没能拿到' + spot.label + '的讲解，稍后再试一次。';

    card.text = speech;
    card.cardType = 'spot';
    card.spotKey = spot.key;
    card.spotSource = fromAlbum ? 'photo' : 'camera';
    card.isThinking = false;
    card.isKnowledge = !this.isIgnoredText(speech);
    this.messages = this.messages.slice();
    await this.saveCurrentSession();
  }

  /** 「确认打卡」：写记录 + 追加汇总卡片 */
  private async confirmCheckin(msg: ChatMessage): Promise<void> {
    const spot: SpotEntry | null = RoutePlanner.findSpot(msg.spotKey);
    if (spot === null) return;
    const source: string = msg.spotSource !== '' ? msg.spotSource : 'camera';
    const wrote: boolean = await this.saveCheckin(spot.key, source);
    if (!wrote) {
      promptAction.showToast({ message: '这个点位已经打过卡了' });
      return;
    }
    this.uploadCheckin(spot, source);
    await this.checkinSummary(spot);
  }

  /** 「还要学习」：给一段引导语，让用户接着问 */
  private askMore(msg: ChatMessage): void {
    const spot: SpotEntry | null = RoutePlanner.findSpot(msg.spotKey);
    const name: string = spot !== null ? spot.label : '这个点位';
    const tip = new ChatMessage(Date.now(), 0,
      '好，关于' + name + '，还有哪里不清楚？战役经过、关键人物、战术细节、遗址情形都可以继续问我。');
    this.messages = this.messages.concat([tip]);
    this.messages = this.messages.slice();
    this.saveCurrentSession();
  }

  /**
   * 打卡汇总卡片。地点清单是动态渲染的（按当前 checkins 实时算颜色），
   * 不是生成时的快照 —— 所以重开 App 后这条卡片会跟着最新记录变色。
   */
  private async checkinSummary(spot: SpotEntry): Promise<void> {
    const total: number = RoutePlanner.allSpots().length;
    const card = new ChatMessage(Date.now() + 1, 0,
      '🎉 恭喜！' + spot.label + ' 打卡完成。你的研学足迹 ' + this.checkedInCount() + ' / ' + total + '，继续加油。');
    card.cardType = 'checkinList';
    this.messages = this.messages.concat([card]);
    this.messages = this.messages.slice();
    await this.saveCurrentSession();
  }

  // 扫码入口：App 内不实现相机扫码，由系统相机扫码后写入 scan_params，
  // 再由 checkScanParams() 回读并自动发起对应讲解。
  private startScan(): void { promptAction.showToast({ message: '请使用系统相机扫描景区二维码，App 会自动识别' }); }

  // ==================== UI 构建 ====================
  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#1A0000', 0.0], ['#3D0000', 0.3], ['#5C0000', 0.7], ['#3D0000', 1.0]]
        })

      Column() {
        Column() {
          Row() {
            Button() {
              Text('☰').fontSize(24).fontColor('#FFD700')
            }
            .width(36).height(36).backgroundColor(Color.Transparent)
            .onClick(() => { this.showHistory = true; })
            Column() {
              Text('小智')
                .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#FFD700')
                .letterSpacing(2)
              Text('松山战役智能讲解员')
                .fontSize(12).fontColor('#FFAAAA')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
            Blank()
            Row() {
              Button() {
                Image($rawfile(this.voiceEnabled ? 'icon_mic.svg' : 'icon_mute.svg')).width(26).height(26)
                  .fillColor(this.voiceEnabled ? '#FFD700' : 'rgba(255,215,0,0.7)')
              }.width(44).height(44).backgroundColor(Color.Transparent)
              .onClick(() => {
                this.voiceEnabled = !this.voiceEnabled;
                promptAction.showToast({ message: this.voiceEnabled ? '语音播报已开启' : '语音播报已关闭' });
                if (!this.voiceEnabled) this.tts.stopSpeaking();
              })
            }
          }.width('100%').height(52).padding({ left: 16, right: 8 })

          if (this.isLoggedIn && this.currentRole === 'student') {
            Row() {
              Button('小学').fontSize(14).height(32).padding({ left: 16, right: 16 })
                .backgroundColor(this.selectedGrade === '小学' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(this.selectedGrade === '小学' ? Color.White : '#FFAAAA').borderRadius(16)
                .onClick(() => { this.pickGrade('小学'); })
              Button('中学').fontSize(14).height(32).padding({ left: 16, right: 16 })
                .backgroundColor(this.selectedGrade === '中学' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(this.selectedGrade === '中学' ? Color.White : '#FFAAAA').borderRadius(16)
                .margin({ left: 12 }).onClick(() => { this.pickGrade('中学'); })
              Button('大学').fontSize(14).height(32).padding({ left: 16, right: 16 })
                .backgroundColor(this.selectedGrade === '大学' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(this.selectedGrade === '大学' ? Color.White : '#FFAAAA').borderRadius(16)
                .margin({ left: 12 }).onClick(() => { this.pickGrade('大学'); })
            }.width('100%').justifyContent(FlexAlign.Center).padding({ bottom: 8 })
          }
        }.width('100%')
        .border({ width: { bottom: 1 }, color: 'rgba(255,215,0,0.25)' })

        Row() {
          Button('模拟子高地').height(36).fontSize(12).backgroundColor('rgba(160,0,0,0.4)')
            .fontColor('#FFAAAA').borderRadius(12).padding({ left: 10, right: 10 })
            .onClick(() => { if (this.requireLogin()) this.checkNearbyPoints(24.7443, 98.9061); })
          Button('模拟纪念碑').height(36).fontSize(12).backgroundColor('rgba(160,0,0,0.4)')
            .fontColor('#FFAAAA').borderRadius(12).padding({ left: 10, right: 10 }).margin({ left: 8 })
            .onClick(() => { if (this.requireLogin()) this.checkNearbyPoints(24.7392, 98.9058); })
          Button('模拟雕塑群').height(36).fontSize(12).backgroundColor('rgba(160,0,0,0.4)')
            .fontColor('#FFAAAA').borderRadius(12).padding({ left: 10, right: 10 }).margin({ left: 8 })
            .onClick(() => { if (this.requireLogin()) this.checkNearbyPoints(24.7397, 98.9055); })
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 4 })
        .opacity(this.isLoggedIn ? 1 : 0.55)

        Stack() {
          List({ scroller: this.scroller }) {
          ForEach(this.messages.filter((m: ChatMessage) => m.id !== 0), (msg: ChatMessage) => {
            ListItem() {
              Row() {
                if (msg.type === 0) {
                  Column() {
                    if (msg.text !== '') {
                      Column() {
                        // 扫码讲解卡片：照片块在最上面；图没放就显占位块 + 地点名
                        if (msg.cardType === 'spot' && msg.spotKey !== '') {
                          Stack() {
                            Column() {
                              Text('照片待补').fontSize(11).fontColor('rgba(255,215,0,0.45)')
                              Text(RoutePlanner.labelOf(msg.spotKey))
                                .fontSize(12).fontColor('rgba(255,215,0,0.7)').margin({ top: 4 })
                            }
                            .width('100%').height('100%').justifyContent(FlexAlign.Center)
                            .backgroundColor('rgba(255,215,0,0.08)')
                            if (RoutePlanner.photoOf(msg.spotKey) !== '') {
                              Image($rawfile(RoutePlanner.photoOf(msg.spotKey)))
                                .width('100%').height('100%').objectFit(ImageFit.Cover)
                            }
                          }
                          // 不能用 width('100%')：气泡是「内容自适应 + constraintSize 限宽」的 Column，
                          // 里面的 100% 会按外层可用宽度解析（比气泡本身宽），加上气泡是 End 对齐，
                          // 超出部分会从左边溢出。这里用确定数值，并扣掉左侧 3vp 的强调边框。
                          .width(this.bubbleMaxW - 3).height(200).borderRadius(12).clip(true)
                          .border({ width: 1, color: 'rgba(255,215,0,0.30)' })
                        }
                        Text(msg.text).fontColor('#FFE9A8').fontSize(this.chatFontSize)
                          // 只有进入选取文字模式的那条才打开原生选取，其余长按给我们自己的菜单
                          .copyOption(this.selectingMsgId === msg.id ? CopyOptions.LocalDevice : CopyOptions.None)
                          .padding({ left: 14, right: 14, top: 14, bottom: 6 })
                        // 只挂在最新气泡上；旧气泡的复制/朗读走长按菜单
                        if (!msg.isThinking && msg.repairProgress === -1 && this.isLatestAnswer(msg)) {
                          Row() {
                            Button() { Image($rawfile('icon_copy.svg')).width(18).height(18).fillColor('#FFD700') }
                            .width(32).height(32).backgroundColor('rgba(255,215,0,0.16)').borderRadius(10)
                            .onClick(() => this.copyTextToClipboard(msg.text))
                            // 只在「上一条是用户提问」的回答上出现：
                            // 路线规划 / 研学报告 / GPS 自动讲解 / 照片修复结果都没有前置提问
                            if (this.precedingQuestion(msg) !== '') {
                              Button() { Image($rawfile('icon_regen.svg')).width(18).height(18).fillColor('#FFD700') }
                              .width(32).height(32).backgroundColor('rgba(255,215,0,0.16)').borderRadius(10)
                              .margin({ left: 8 })
                              .onClick(() => { this.regenerateAnswer(msg.id); })
                            }
                            Button() { Image($rawfile('icon_mic.svg')).width(18).height(18).fillColor('#FFD700') }
                            .width(32).height(32).backgroundColor('rgba(255,215,0,0.16)').borderRadius(10)
                            .margin({ left: 8 })
                            .onClick(() => this.playAudio(msg))
                          }
                          .padding({ left: 10, right: 10, bottom: 8 })
                        }
                        // 扫码讲解卡片的打卡区：未打卡给两个按钮，已打卡变灰
                        if (msg.cardType === 'spot' && msg.spotKey !== '') {
                          Row() {
                            if (this.isCheckedIn(msg.spotKey)) {
                              Text('✓ 已打卡 · ' + new Date(this.checkinTime(msg.spotKey)).toLocaleTimeString())
                                .fontSize(13).fontColor('rgba(255,255,255,0.45)')
                                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                                .backgroundColor('rgba(255,255,255,0.10)').borderRadius(18)
                            } else {
                              Button('确认打卡 · ' + RoutePlanner.labelOf(msg.spotKey))
                                .height(38).fontSize(13).fontColor('#2A0000')
                                .backgroundColor('#FFD700').borderRadius(19)
                                .onClick(() => { this.confirmCheckin(msg); })
                            }
                            Button('还要学习')
                              .height(38).fontSize(13).fontColor('#FFD700')
                              .backgroundColor('rgba(255,215,0,0.14)').borderRadius(19)
                              .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
                              .margin({ left: 10 })
                              .onClick(() => { this.askMore(msg); })
                          }
                          .padding({ left: 10, right: 10, bottom: 10 })
                        }
                        // 打卡汇总：全部 12 个地点。已打卡 = 绿 ✓，未打卡 = 灰 ○
                        if (msg.cardType === 'checkinList') {
                          Flex({ wrap: FlexWrap.Wrap }) {
                            ForEach(RoutePlanner.allSpots(), (s: SpotEntry) => {
                              Row() {
                                Text(this.isCheckedIn(s.key) ? '✓' : '○').fontSize(12)
                                  .fontColor(this.isCheckedIn(s.key) ? '#7CE38B' : 'rgba(255,255,255,0.35)')
                                Text(s.label).fontSize(12).margin({ left: 4 })
                                  .fontColor(this.isCheckedIn(s.key) ? '#7CE38B' : 'rgba(255,255,255,0.35)')
                              }
                              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                              .margin({ right: 6, bottom: 6 }).borderRadius(10)
                              .backgroundColor(this.isCheckedIn(s.key) ? 'rgba(124,227,139,0.12)' : 'rgba(255,255,255,0.06)')
                            }, (s: SpotEntry) => s.key + (this.isCheckedIn(s.key) ? '_c' : '_n'))
                          }
                          .width(this.bubbleMaxW - 3).padding({ left: 10, right: 10, bottom: 10 })
                        }
                      }
                      .alignItems(HorizontalAlign.End)
                      .backgroundColor('rgba(255,215,0,0.10)')
                      .border({ width: { left: 3 }, color: 'rgba(255,215,0,0.55)' })
                      .borderRadius(14).shadow({ radius: 14, color: 'rgba(255,215,0,0.20)' })
                      .constraintSize({ maxWidth: this.bubbleMaxW }).margin({ bottom: 6 })
                      // parallelGesture 而非 gesture：进入选取模式后要让原生选词也能收到长按，
                      // 此时处理函数直接 return，不消费事件
                      .parallelGesture(LongPressGesture({ repeat: false, duration: 300 })
                        .onAction(() => {
                          if (this.selectingMsgId === msg.id) return;
                          this.bubbleMenuId = this.bubbleMenuId === msg.id ? 0 : msg.id;
                        }))
                    }
                    if (msg.suggestions.length > 0) {
                      Column() {
                        Text('猜你想问')
                          .fontSize(11).fontColor('rgba(255,215,0,0.6)')
                          .margin({ bottom: 6 })
                        ForEach(msg.suggestions, (q: string, idx: number) => {
                          Button() {
                            Text(q).fontSize(12).fontColor('#FFE9A8')
                              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                          .width('100%').height(32).padding({ left: 12, right: 12 })
                          .backgroundColor('rgba(255,215,0,0.06)')
                          .border({ width: 1, color: 'rgba(255,215,0,0.22)' })
                          .borderRadius(16).margin({ bottom: 6 })
                          .opacity(idx < this.suggestShown ? 1 : 0)
                          .translate({ y: idx < this.suggestShown ? 0 : 10 })
                          .animation({ duration: 240, curve: Curve.EaseOut })
                          .onClick(() => { this.inputText = q; this.sendMessage(); })
                        }, (q: string) => q)
                      }
                      .width('88%').alignItems(HorizontalAlign.Start)
                      .margin({ bottom: 10 })
                    }
                    if (msg.imagePixelMap) {
                      Image(msg.imagePixelMap).width(120).height(120)
                        .objectFit(ImageFit.Cover).borderRadius(8).margin({ bottom: 4 })
                        .onClick(() => {
                          this.previewPixelMap = msg.imagePixelMap;
                          this.previewVisible = true;
                        })
                    }
                    if (msg.repairProgress >= 0 && msg.repairProgress < 100) {
                      Column() {
                        Text(msg.text || '准备修复...').fontSize(12).fontColor('#FFE9A8').margin({ bottom: 4 })
                        Progress({ value: msg.repairProgress, total: 100, type: ProgressType.Linear })
                          .width('100%').height(8).color('#FFD700').backgroundColor('rgba(255,215,0,0.18)')
                        Text(`${msg.repairProgress}%`).fontSize(12).fontColor('#FFD700').margin({ top: 4 })
                      }.width(200).backgroundColor('rgba(255,215,0,0.15)').borderRadius(12).padding(12)
                    }
                    if (msg.isThinking) {
                      Row() {
                        Stack() {
                          Column()
                            .width(18)
                            .height(18)
                            .border({ width: 2, color: '#FFD700' })
                            .rotate({ angle: this.rotateAngle })
                            .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
                          Column()
                            .width(12)
                            .height(12)
                            .border({ width: 2, color: '#FFD700' })
                            .rotate({ angle: -this.rotateAngle })
                            .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
                        }
                        .width(22)
                        .height(22)
                        .alignContent(Alignment.Center)

                        Text('正在思考...')
                          .fontSize(this.chatFontSize)
                          .fontColor('#FFAAAA')
                          .margin({ left: 8 })
                      }
                      .margin({ top: 6 })
                    }
                    if (this.bubbleMenuId === msg.id) { this.bubbleMenu(msg) }
                  }.alignItems(HorizontalAlign.Start)
                } else {
                  Blank()
                  Column() {
                    if (msg.imagePixelMap) {
                      Image(msg.imagePixelMap).width(120).height(120)
                        .objectFit(ImageFit.Cover).borderRadius(8).margin({ bottom: 4 })
                        .onClick(() => {
                          this.previewPixelMap = msg.imagePixelMap;
                          this.previewVisible = true;
                        })
                    }
                    if (msg.text !== '') {
                      Column() {
                        Text(msg.text).fontColor('#FFF8DC').fontSize(this.chatFontSize)
                          .copyOption(this.selectingMsgId === msg.id ? CopyOptions.LocalDevice : CopyOptions.None)
                          .padding({ left: 14, right: 14, top: 14, bottom: msg.text.length >= 6 ? 6 : 14 })
                        if (msg.text.length >= 6) {
                          Row() {
                            Button() { Image($rawfile('icon_copy.svg')).width(18).height(18).fillColor('#FFF8DC') }
                            .width(32).height(32).backgroundColor('rgba(255,248,220,0.16)').borderRadius(10)
                            .onClick(() => this.copyTextToClipboard(msg.text))
                          }
                          .padding({ left: 10, right: 10, bottom: 8 })
                        }
                      }
                      .alignItems(HorizontalAlign.End)
                      .backgroundColor('rgba(255,215,0,0.30)')
                      .border({ width: { right: 3 }, color: '#FFD700' })
                      .borderRadius(14).shadow({ radius: 10, color: 'rgba(255,215,0,0.30)' })
                      .constraintSize({ maxWidth: this.bubbleMaxW }).margin({ bottom: 6 })
                      .parallelGesture(LongPressGesture({ repeat: false, duration: 300 })
                        .onAction(() => {
                          if (this.selectingMsgId === msg.id) return;
                          this.bubbleMenuId = this.bubbleMenuId === msg.id ? 0 : msg.id;
                        }))
                    }
                    if (this.bubbleMenuId === msg.id) { this.bubbleMenu(msg) }
                  }.alignItems(HorizontalAlign.End)
                }
              }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
            }
          // 键必须包含所有会原地变化的字段。只写 msg.id 的话，原地改
          // text / isThinking / repairProgress 时键不变，ArkUI 复用旧组件、
          // 不重跑 builder，界面永远停在旧内容 —— 重新生成和照片修复进度条都栽在这里。
          // 这是本项目第三次踩同一个坑（前两次：侧边栏置顶针、侧边栏标题）。
          }, (msg: ChatMessage) => this.messageKey(msg))

          // 尾部占位 item：替代 List 的 bottom padding。
          // List.padding 与虚拟化 + scrollEdge(Edge.Bottom) 配合不可靠，
          // 用真实 item 才能保证最后一条消息不被输入栏压住。
          ListItem() {
            Column().width('100%').height(96)
          }
          }
          .onScrollStart(() => {
            if (!this.isProgrammaticScroll) {
              this.autoScrollEnabled = false;
              this.closeBubbleMenu();
            }
          })
          .width('100%').height('100%').scrollBar(BarState.Auto)
          .padding({ top: 8 })

          if (this.isNewChat()) {
            Column() {
              // 保留中央主Logo
              Image($r('app.media.logo'))
                .width(110)
                .height(110)
                .objectFit(ImageFit.Contain)
                .hitTestBehavior(HitTestMode.None)
                .margin({ bottom: 8 })

              // 研学引导主副标题
              Text('松山战役数字研学 · 阵地已连通')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFD700')
                .letterSpacing(1.2)
                .textAlign(TextAlign.Center)

              Text('1944年，中国远征军在这座山上打了95天')
                .fontSize(12)
                .fontColor('#FFAAAA')
                .margin({ top: 4, bottom: 14 })

              // 三个快捷研学问题胶囊
              Column({ space: 8 }) {
                Button() {
                  Text('“松山战役为什么被称为东方马其诺防线？”')
                    .fontSize(13).fontColor('#FFE9A8').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').height(38).padding({ left: 14, right: 14 })
                .backgroundColor('rgba(255, 215, 0, 0.08)')
                .border({ width: 1, color: 'rgba(255, 215, 0, 0.28)' })
                .borderRadius(14)
                .onClick(() => { this.inputText = '松山战役为什么被称为东方马其诺防线？'; this.sendMessage(); })

                Button() {
                  Text('“子高地的3吨炸药坑道爆破是怎么做到的？”')
                    .fontSize(13).fontColor('#FFE9A8').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').height(38).padding({ left: 14, right: 14 })
                .backgroundColor('rgba(255, 215, 0, 0.08)')
                .border({ width: 1, color: 'rgba(255, 215, 0, 0.28)' })
                .borderRadius(14)
                .onClick(() => { this.inputText = '子高地的3吨炸药坑道爆破是怎么做到的？'; this.sendMessage(); })

                Button() {
                  Text('“中国远征军雕塑群的娃娃兵方阵有怎样的故事？”')
                    .fontSize(13).fontColor('#FFE9A8').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').height(38).padding({ left: 14, right: 14 })
                .backgroundColor('rgba(255, 215, 0, 0.08)')
                .border({ width: 1, color: 'rgba(255, 215, 0, 0.28)' })
                .borderRadius(14)
                .onClick(() => { this.inputText = '中国远征军雕塑群的娃娃兵方阵有怎样的故事？'; this.sendMessage(); })
              }
              .width('100%')

              if (!this.isLoggedIn) {
                Row() {
                  Button('登录')
                    .height(34).padding({ left: 20, right: 20 }).fontSize(13)
                    .backgroundColor('#8B0000').fontColor('#FFD700').borderRadius(17)
                    .onClick(() => { router.pushUrl({ url: 'pages/LoginPage' }); })
                }
                .margin({ top: 12 })
              }
            }
            .width('88%')
            .alignItems(HorizontalAlign.Center)
            .translate({ y: -10 })
          }
        }
        .layoutWeight(1)

        Column() {
          // 关掉路线页后的提示气泡，居中压在「规划路线」（中间那个按钮）上方
          if (this.showRouteHint) {
            Row() {
              Blank().layoutWeight(1)
              Text('想再查看路线点我')
                .fontSize(14).fontColor('#FFD700').fontWeight(FontWeight.Medium)
                .padding({ left: 16, right: 16, top: 9, bottom: 9 })
                .backgroundColor('rgba(190,20,20,0.80)')
                .borderRadius(14)
                .border({ width: 1, color: 'rgba(255,215,0,0.65)' })
                .onClick(() => { this.showRouteHint = false; this.openRoutePlan(); })
              Blank().layoutWeight(1)
            }
            .width('100%').padding({ top: 8 })
          }

          // 四个功能按钮改横向滚动：按钮固定宽度，窄屏也放得下、不会把文字压成两行
          Scroll() {
            Row() {
              Button('修复照片').width(96).height(44).backgroundColor('rgba(160,0,0,0.4)')
                .fontColor('#FFD700').fontSize(14).borderRadius(12)
                .onClick(() => { if (this.requireLoginAllowTourist()) this.handlePhotoRepair(); })
              Button('规划路线').width(96).height(44).backgroundColor('rgba(160,0,0,0.4)')
                .fontColor('#FFD700').fontSize(14).borderRadius(12)
                .margin({ left: 8 }).onClick(() => { if (this.requireLogin()) this.openRoutePlan(); })
              Button('生成报告').width(96).height(44).backgroundColor('rgba(160,0,0,0.4)')
                .fontColor('#FFD700').fontSize(14).borderRadius(12)
                .margin({ left: 8 }).onClick(() => { if (this.requireLogin()) this.handleGenerateReport(); })
              Button('出题测试').width(96).height(44).backgroundColor('rgba(160,0,0,0.4)')
                .fontColor('#FFD700').fontSize(14).borderRadius(12)
                .margin({ left: 8 }).onClick(() => { if (this.requireLogin()) this.openQuiz(true); })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 4 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%').height(56)
          .backdropBlur(4)
          .opacity(this.isLoggedIn ? 1 : 0.55)

          Row() {
            Row() {
              TextInput({ text: this.inputText, placeholder: '请输入消息或长按麦克风说话' })
                .id('messageInput').onChange((value: string) => { this.inputText = value; }).onSubmit(() => this.sendMessage())
                .layoutWeight(1).height(46).backgroundColor(Color.Transparent)
                .fontColor('#FFF8DC').placeholderColor('rgba(255,233,168,0.5)')

              Button() {
                Image($rawfile('icon_voice.svg')).width(22).height(22)
                  .fillColor(this.isRecording ? '#FFD700' : 'rgba(255,215,0,0.5)')
              }
              .width(40).height(40).backgroundColor(Color.Transparent).borderRadius(20)
              .gesture(LongPressGesture({ repeat: false, duration: 300 })
                .onAction(() => { if (this.requireLogin()) this.startRecording(); })
                .onActionEnd(() => { if (this.isRecording) this.stopAndRecognize(); }))
              .onClick(() => { if (!this.isRecording) promptAction.showToast({ message: '请长按麦克风按钮说话' }); })

              Button() { Image($rawfile('icon_send.svg')).width(22).height(22).fillColor('#FFF8DC') }
              .width(40).height(40).backgroundColor('#8B0000').borderRadius(20).margin({ left: 4 }).onClick(() => this.sendMessage())
            }
            .layoutWeight(1).height(48).backgroundColor('rgba(255,215,0,0.10)').borderRadius(24)
            .border({ width: 1, color: 'rgba(255,215,0,0.45)' })
            .padding({ left: 14, right: 6 })
            .alignItems(VerticalAlign.Center)
          }.width('100%').padding(10)
        }
        .width('100%')
      }
      .width('100%').height('100%')

      if (this.showVoicePanel) {
        Column() {
          Column().width('100%').layoutWeight(1).backgroundColor('rgba(0,0,0,0.5)')
            .onClick(() => { if (this.isRecording) this.cancelCurrentRecording(); })
          Column() {
            Text(this.isRecognizing ? '正在识别...' : '正在聆听...').fontSize(16).fontColor('#FFD700').margin({ top: 20, bottom: 12 })
            if (this.isRecording && !this.isRecognizing) {
              Row() {
                ForEach(WAVE_BARS, (bar: number) => {
                  Column().width(6).height(10 + (bar <= this.voiceWaveLevel ? bar * 8 : 4))
                    .backgroundColor('#FFD700').borderRadius(3).margin({ left: 4, right: 4 })
                }, (bar: number) => bar.toString())
              }.justifyContent(FlexAlign.Center).height(60)
              Text(this.formatDuration(this.recordingDuration)).fontSize(32).fontColor('#FFD700').margin({ bottom: 20 })
            }
            if (this.isRecognizing) {
              Progress({ value: 0, total: 100, type: ProgressType.ScaleRing })
                .width(48).height(48).color('#FFD700').margin({ top: 20, bottom: 30 })
            }
          }.width('100%').backgroundColor('rgba(160,0,0,0.4)').borderRadius({ topLeft: 24, topRight: 24 })
        }.width('100%').height('100%').position({ x: 0, y: 0 }).zIndex(100)
      }

      if (this.showRouteDialog) {
        Column() {
          Column() {
            Text('路线规划').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2E0000').margin({ bottom: 16 })
            Row() {
              Text('年级：').fontSize(16).fontColor('#2E0000')
              Select([{ value: '小学' }, { value: '中学' }, { value: '大学' }])
                .selected(this.selectedGrade === '小学' ? 0 : (this.selectedGrade === '中学' ? 1 : 2))
                .onSelect((index: number) => {
                  if (index === 0) this.selectedGrade = '小学';
                  else if (index === 1) this.selectedGrade = '中学';
                  else this.selectedGrade = '大学';
                })
            }.width('100%').margin({ bottom: 12 })
            Row() {
              Text('时长：').fontSize(16).fontColor('#2E0000')
              Select([{ value: '1h' }, { value: '2h' }, { value: '3h' }])
                .selected(this.selectedHours === '1h' ? 0 : (this.selectedHours === '2h' ? 1 : 2))
                .onSelect((index: number) => {
                  if (index === 0) this.selectedHours = '1h';
                  else if (index === 1) this.selectedHours = '2h';
                  else this.selectedHours = '3h';
                })
            }.width('100%').margin({ bottom: 20 })
            Row() {
              Button('取消').width('40%').height(40).backgroundColor('rgba(160,0,0,0.4)').fontColor('#FFD700').borderRadius(8).onClick(() => { this.showRouteDialog = false; })
              Button('确定').width('40%').height(40).backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(8).margin({ left: 12 })
                .onClick(() => { this.showRouteDialog = false; this.executeRoutePlan(); })
            }.width('100%').justifyContent(FlexAlign.Center)
          }.padding(20).backgroundColor('#FFF8DC').borderRadius(16).width('80%')
        }.width('100%').height('100%').backgroundColor('rgba(0,0,0,0.5)').justifyContent(FlexAlign.Center).onClick(() => { this.showRouteDialog = false; })
      }

      // 生成中遮罩：路线规划 / 研学报告共用。
      // 动画刻意复用对话回复那套（两个反向旋转的方框）—— 由 aboutToAppear 里
      // 已有的 rotateAngle 定时器驱动，不用另起计时器。
      if (this.showGenerating) {
        Column() {
          Stack() {
            Column()
              .width(46).height(46)
              .border({ width: 3, color: '#FFD700' })
              .rotate({ angle: this.rotateAngle })
              .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
            Column()
              .width(30).height(30)
              .border({ width: 3, color: '#FFD700' })
              .rotate({ angle: -this.rotateAngle })
              .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
          }
          .width(56).height(56).alignContent(Alignment.Center)

          Text(this.generatingText).fontSize(15).fontColor('#FFAAAA').margin({ top: 18 })
        }
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.78)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(240)
      }

      // 出题测试全屏页。zIndex 245 压过路线页（220）/ 侧边栏（210）/ 生成中遮罩（240）。
      if (this.showQuizView) {
        Column() {
          Row() {
            Text('研学测试').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFD700')
            Text(this.quizGrade + '段 · ' +
              (this.quizStage === 'done' ? '满分 ' + QUIZ_FULL_SCORE
                : specTotalCount(this.quizSpec) + ' 题'))
              .fontSize(12).fontColor('#FFAAAA').margin({ left: 8 }).layoutWeight(1)
            Button() {
              Image($rawfile('icon_close_bold.svg')).width(18).height(18).fillColor('#FFD700')
            }
            .width(36).height(36).backgroundColor(Color.Transparent)
            .onClick(() => { this.saveQuizProgress(); this.stopQuizTimer(); this.showAnswerSheet = false; this.showQuizView = false; })
          }
          .width('100%').padding({ left: 20, right: 8, top: 16, bottom: 8 })

          Divider().strokeWidth(1).color('rgba(255,215,0,0.25)')

          // ---------- 抽题中 ----------
          // 复用工程自己的双框反向转圈 —— 对话「正在思考」与生成中遮罩都是这套，
          // 由 aboutToAppear 起的 rotateAngle 定时器驱动，不另开计时器。
          if (this.quizStage === 'generating') {
            Column() {
              Stack() {
                Column()
                  .width(46).height(46)
                  .border({ width: 3, color: '#FFD700' })
                  .rotate({ angle: this.rotateAngle })
                  .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
                Column()
                  .width(30).height(30)
                  .border({ width: 3, color: '#FFD700' })
                  .rotate({ angle: -this.rotateAngle })
                  .animation({ duration: 2000, iterations: -1, curve: Curve.Linear })
              }
              .width(56).height(56).alignContent(Alignment.Center)

              Text('正在抽题…')
                .fontSize(15).fontColor('#FFAAAA').margin({ top: 18 })
              Text('共 ' + specTotalCount(this.quizSpec) + ' 题')
                .fontSize(12).fontColor('rgba(255,170,170,0.6)').margin({ top: 8 })
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          }

          // ---------- 作答中 ----------
          if (this.quizStage === 'answering') {
            // 用 List 而不是 Scroll：只有 List 支持 scrollToIndex，答题卡按题号跳转要靠它。
            // Scroll 只能按像素偏移，而各题高度差异很大（单选四行、判断一行、简答一个大输入框），
            // 靠累加高度算偏移不可靠。
            List({ scroller: this.quizScroller }) {
              ForEach(this.quizQuestions, (q: QuizQuestion, index: number) => {
                ListItem() {
                  Column() {
                    Row() {
                      Text(`${index + 1}`).fontSize(12).fontColor('#2A0000').fontWeight(FontWeight.Bold)
                        .width(22).height(22).textAlign(TextAlign.Center)
                        .backgroundColor('#FFD700').borderRadius(11)
                      Text(this.kindLabel(q.kind))
                        .fontSize(11).fontColor('rgba(255,215,0,0.55)').margin({ left: 8 })
                      Blank()
                      Text(this.questionScoreText(q))
                        .fontSize(11).fontColor('rgba(255,215,0,0.55)')
                    }.width('100%')

                    Text(q.stem).fontSize(this.chatFontSize).fontColor('#FFE9A8')
                      .width('100%').margin({ top: 10 })

                    if (q.kind === 'single' || q.kind === 'multi') {
                      ForEach(q.options, (opt: string, oi: number) => {
                        Row() {
                          Text(String.fromCharCode(65 + oi)).fontSize(12)
                            .fontColor(this.isOptionPicked(index, String.fromCharCode(65 + oi))
                              ? '#2A0000' : 'rgba(255,215,0,0.7)')
                            .width(22).height(22).textAlign(TextAlign.Center)
                            .backgroundColor(this.isOptionPicked(index, String.fromCharCode(65 + oi))
                              ? '#FFD700' : 'rgba(255,215,0,0.12)')
                            // 单选画圆、多选画方：形状本身就提示"这道题能选几个"
                            .borderRadius(q.kind === 'multi' ? 4 : 11)
                          Text(opt).fontSize(this.chatFontSize).fontColor('#FFF8DC')
                            .margin({ left: 10 }).layoutWeight(1)
                        }
                        .width('100%').padding(10).borderRadius(10).margin({ top: 8 })
                        .backgroundColor(this.isOptionPicked(index, String.fromCharCode(65 + oi))
                          ? 'rgba(255,215,0,0.22)' : 'rgba(255,215,0,0.06)')
                        .border({
                          width: 1,
                          color: this.isOptionPicked(index, String.fromCharCode(65 + oi))
                            ? 'rgba(255,215,0,0.7)' : 'rgba(255,215,0,0.18)'
                        })
                        .onClick(() => { this.pickAnswer(index, String.fromCharCode(65 + oi)); })
                      }, (opt: string, oi: number) => index.toString() + '_' + oi.toString() + '_' +
                        (this.isOptionPicked(index, String.fromCharCode(65 + oi)) ? 's' : 'n'))
                    } else if (q.kind === 'judge') {
                      Row() {
                        Button('对').layoutWeight(1).height(40).fontSize(14).borderRadius(10)
                          .fontColor(this.quizAnswers[index] === 'T' ? '#2A0000' : '#FFD700')
                          .backgroundColor(this.quizAnswers[index] === 'T' ? '#FFD700' : 'rgba(255,215,0,0.10)')
                          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
                          .onClick(() => { this.pickAnswer(index, 'T'); })
                        Button('错').layoutWeight(1).height(40).fontSize(14).borderRadius(10)
                          .fontColor(this.quizAnswers[index] === 'F' ? '#2A0000' : '#FFD700')
                          .backgroundColor(this.quizAnswers[index] === 'F' ? '#FFD700' : 'rgba(255,215,0,0.10)')
                          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
                          .margin({ left: 10 })
                          .onClick(() => { this.pickAnswer(index, 'F'); })
                      }.width('100%').margin({ top: 10 })
                    } else if (q.kind === 'blank') {
                      TextInput({ text: this.quizAnswers[index], placeholder: '在此填写答案' })
                        .height(44).fontSize(this.chatFontSize)
                        .backgroundColor('rgba(255,215,0,0.08)')
                        .fontColor('#FFF8DC').placeholderColor('rgba(255,233,168,0.4)')
                        .border({ width: 1, color: 'rgba(255,215,0,0.3)' }).borderRadius(10)
                        .margin({ top: 10 })
                        .onChange((value: string) => { this.pickAnswer(index, value); })
                    } else {
                      TextArea({ text: this.quizAnswers[index], placeholder: '在此作答，尽量把要点写清楚' })
                        .height(120).fontSize(this.chatFontSize)
                        .backgroundColor('rgba(255,215,0,0.08)')
                        .fontColor('#FFF8DC').placeholderColor('rgba(255,233,168,0.4)')
                        .border({ width: 1, color: 'rgba(255,215,0,0.3)' }).borderRadius(10)
                        .margin({ top: 10 })
                        .onChange((value: string) => { this.pickAnswer(index, value); })
                    }
                  }
                  .width('100%').padding(14)
                  .backgroundColor('rgba(255,215,0,0.08)')
                  .borderRadius(14)
                  .border({ width: 1, color: 'rgba(255,215,0,0.22)' })
                  .margin({ bottom: 12 })
                }
                }, (q: QuizQuestion, index: number) =>
                  // 选择题型把「已选答案」编进键，选中后才会重建高亮；
                  // 填空/简答绝不能把答案编进键 —— 那样每敲一个字都会重建输入框、焦点立刻丢失。
                  (q.kind === 'blank' || q.kind === 'short')
                    ? 'text_' + index.toString()
                    : index.toString() + '_' +
                      (this.quizAnswers[index] === undefined ? '' : this.quizAnswers[index]))
            }
            .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
            .padding({ left: 16, right: 16, top: 12 })

            // 答题卡入口。展开后是一个盖在整页之上的面板，点题号直接跳到那一题。
            Row() {
              Text('答题卡').fontSize(13).fontColor('#FFD700')
              Text('点题号可跳转').fontSize(12).fontColor('#FFAAAA').margin({ left: 8 }).layoutWeight(1)
              Text(this.showAnswerSheet ? '收起 ▲' : '展开 ▼').fontSize(12).fontColor('#FFAAAA')
            }
            .width('100%').padding({ left: 20, right: 20, top: 10 })
            .onClick(() => { this.showAnswerSheet = !this.showAnswerSheet; })

            Row() {
              Text('已作答 ' + this.answeredCount() + ' / ' + this.quizQuestions.length)
                .fontSize(13).fontColor('#FFAAAA').layoutWeight(1)
              Text(this.remainText())
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(this.quizRemainSec <= QUIZ_WARN_SEC ? '#FF6B6B' : '#FFD700')
                .margin({ right: 12 })
              Button('交卷')
                .height(40).fontSize(14).fontColor('#FFF8DC')
                .backgroundColor('#8B0000').borderRadius(20).padding({ left: 24, right: 24 })
                .onClick(() => { this.submitQuiz(false); })
            }
            .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 20 })
            .border({ width: { top: 1 }, color: 'rgba(255,215,0,0.25)' })

            // 答题卡面板：盖在整页之上。已作答的格子是实心金底 + 深色数字，
            // 与题号徽标、选中选项同一套语义 ——「填实 = 已完成」，所以视觉上最重。
            if (this.showAnswerSheet) {
              Column() {
                Column() {
                  Text('答题卡').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFD700')
                  Text('已作答 ' + this.answeredCount() + ' / ' + this.quizQuestions.length
                    + '　点题号跳转')
                    .fontSize(12).fontColor('#FFAAAA').margin({ top: 6 })
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.quizQuestions, (q: QuizQuestion, index: number) => {
                      Text(`${index + 1}`)
                        .width(38).height(38).textAlign(TextAlign.Center)
                        .fontSize(13).fontWeight(FontWeight.Bold)
                        .borderRadius(8).margin({ right: 8, top: 8 })
                        .fontColor(this.quizAnswers[index] !== ''
                          ? '#2A0000' : 'rgba(255,215,0,0.55)')
                        .backgroundColor(this.quizAnswers[index] !== ''
                          ? '#FFD700' : 'rgba(255,215,0,0.07)')
                        .border({
                          width: 1,
                          color: this.quizAnswers[index] !== ''
                            ? '#FFD700' : 'rgba(255,215,0,0.28)'
                        })
                        .onClick(() => { this.jumpToQuestion(index); })
                    }, (q: QuizQuestion, index: number) => 'sheet_' + index.toString() +
                      (this.quizAnswers[index] !== '' ? '_a' : '_n'))
                  }
                  .width('100%').margin({ top: 12 })
                }
                .width('86%').padding(18)
                .backgroundColor('#2A0000')
                .borderRadius(16)
                .border({ width: 1, color: 'rgba(255,215,0,0.4)' })
                .onClick(() => {})
              }
              .width('100%').height('100%')
              .backgroundColor('rgba(0,0,0,0.72)')
              .justifyContent(FlexAlign.Center)
              .position({ x: 0, y: 0 }).zIndex(120)
              .onClick(() => { this.showAnswerSheet = false; })
            }
          }

          // ---------- 判分中 ----------
          if (this.quizStage === 'grading') {
            Column() {
              LoadingProgress().width(48).height(48).color('#FFD700')
              Text('正在判分…').fontSize(15).fontColor('#FFAAAA').margin({ top: 16 })
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          }

          // ---------- 已出分 ----------
          if (this.quizStage === 'done') {
            Scroll() {
              Column() {
                if (this.quizError !== '') {
                  Text(this.quizError).fontSize(this.chatFontSize).fontColor('#FFAAAA')
                    .width('100%').padding(16)
                  Button('重试')
                    .height(42).fontSize(14).fontColor('#FFD700')
                    .backgroundColor('rgba(255,215,0,0.14)').borderRadius(21)
                    .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
                    .margin({ top: 12 })
                    .onClick(() => { this.restartQuiz(); })
                } else {
                  Column() {
                    Text(String(this.quizScore)).fontSize(52).fontWeight(FontWeight.Bold).fontColor('#FFD700')
                    Text('/ ' + QUIZ_FULL_SCORE + ' 分').fontSize(14).fontColor('#FFAAAA').margin({ top: 4 })
                    if (this.quizMe !== null) {
                      Text('本班第 ' + this.quizMe.rank + ' 名' +
                        (this.quizMe.className !== '' ? '（' + this.quizMe.className + '）' : ''))
                        .fontSize(14).fontColor('#7CE38B').margin({ top: 10 })
                    }
                  }
                  .width('100%').padding(24)
                  .backgroundColor('rgba(255,215,0,0.10)')
                  .borderRadius(16)
                  .border({ width: 1, color: 'rgba(255,215,0,0.3)' })

                  // 上传/排名环节的提示。以前失败是静默的，界面上只表现成「没有排名」
                  if (this.quizGradeNote !== '') {
                    Text(this.quizGradeNote).fontSize(12).fontColor('#FFAAAA')
                      .width('100%').margin({ top: 10 }).textAlign(TextAlign.Center)
                  }
                  if (this.quizRankNote !== '') {
                    Text(this.quizRankNote).fontSize(12).fontColor('#FFAAAA')
                      .width('100%').margin({ top: 6 }).textAlign(TextAlign.Center)
                  }

                  if (this.quizRanking.length > 0) {
                    Text('本班排名').fontSize(15).fontColor('#FFD700').fontWeight(FontWeight.Medium)
                      .width('100%').margin({ top: 20, bottom: 4 })
                    ForEach(this.quizRanking.slice(0, 10), (r: QuizRankItem) => {
                      Row() {
                        Text(String(r.rank)).fontSize(13)
                          .fontColor(r.rank <= 3 ? '#FFD700' : '#FFAAAA')
                          .width(28).textAlign(TextAlign.Center)
                        Text(r.name !== '' ? r.name : '（未填姓名）')
                          .fontSize(this.chatFontSize).fontColor('#FFF8DC')
                          .margin({ left: 8 }).layoutWeight(1)
                        Text(r.score + ' / ' + r.total).fontSize(13).fontColor('#FFAAAA')
                      }
                      .width('100%').padding({ top: 8, bottom: 8 })
                      .border({ width: { bottom: 1 }, color: 'rgba(255,215,0,0.12)' })
                    }, (r: QuizRankItem) => r.userId.toString() + '_' + r.score.toString())
                  }

                  Text('逐题解析').fontSize(15).fontColor('#FFD700').fontWeight(FontWeight.Medium)
                    .width('100%').margin({ top: 20, bottom: 4 })
                  ForEach(this.quizQuestions, (q: QuizQuestion, index: number) => {
                    Column() {
                      Row() {
                        if (q.kind === 'short') {
                          // 简答没有「正确/错误」可言，标个题型即可，得分率在下方展示
                          Text('简答').fontSize(11).fontColor('#FFD700')
                            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                            .backgroundColor('rgba(255,215,0,0.16)').borderRadius(8)
                        } else {
                          Text(this.isAnswerRight(q, this.quizAnswers[index]) ? '✓' : '✗')
                            .fontSize(15)
                            .fontColor(this.isAnswerRight(q, this.quizAnswers[index]) ? '#7CE38B' : '#FF8A8A')
                        }
                        Text((index + 1) + '. ' + q.stem).fontSize(this.chatFontSize)
                          .fontColor('#FFE9A8').margin({ left: 8 }).layoutWeight(1)
                      }.width('100%').alignItems(VerticalAlign.Top)

                      if (q.kind === 'short') {
                        Text('你的作答：' + (this.quizAnswers[index] === '' ? '未作答' : this.quizAnswers[index]))
                          .fontSize(12).fontColor('#FFAAAA').width('100%').margin({ top: 6 })
                        Text('参考答案要点：' + q.answer)
                          .fontSize(12).fontColor('#7CE38B').width('100%').margin({ top: 4 })
                      } else {
                        Text('你的答案：' + this.answerText(q, this.quizAnswers[index]) +
                          '　正确答案：' + this.answerText(q, q.answer))
                          .fontSize(12).fontColor('#FFAAAA').width('100%').margin({ top: 6 })
                      }
                      if (q.explain !== '') {
                        Text(q.explain).fontSize(12).fontColor('rgba(255,170,170,0.75)')
                          .width('100%').margin({ top: 4 })
                      }
                    }
                    .width('100%').padding({ top: 10, bottom: 10 })
                    .border({ width: { bottom: 1 }, color: 'rgba(255,215,0,0.10)' })
                  }, (q: QuizQuestion, index: number) => 'exp_' + index.toString())

                  Button('重新出题')
                    .height(42).fontSize(14).fontColor('#FFD700')
                    .backgroundColor('rgba(255,215,0,0.14)').borderRadius(21)
                    .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
                    .margin({ top: 20, bottom: 24 })
                    .onClick(() => { this.restartQuiz(); })
                }
              }
              .width('100%').padding({ left: 16, right: 16, top: 12 })
            }
            .layoutWeight(1).scrollBar(BarState.Auto)
          }
        }
        .width('100%').height('100%').backgroundColor('#1A0000')
        .position({ x: 0, y: 0 }).zIndex(245)
      }

      if (this.showRouteView) {
        Column() {
          // 顶部标题栏
          Row() {
            Text('路线规划').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFD700')
            Text(`${this.routeGrade} · ${this.routeHours}`)
              .fontSize(12).fontColor('#FFAAAA').margin({ left: 8 }).layoutWeight(1)
            Button('重新生成')
              .height(32).fontSize(13).fontColor('#FFD700')
              .backgroundColor('rgba(255,215,0,0.14)').borderRadius(16)
              .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
              .margin({ right: 6 })
              // 选择弹窗没设 zIndex（默认 0），会被路线页（220）压住看不见，
              // 所以必须先关掉路线页再弹；确认后 executeRoutePlan 会把路线页重新打开
              .onClick(() => { this.showRouteView = false; this.openRoutePicker(); })
            Button() {
              Image($rawfile('icon_close_bold.svg')).width(18).height(18).fillColor('#FFD700')
            }
            .width(36).height(36).backgroundColor(Color.Transparent)
            .onClick(() => {
              this.showRouteView = false;
              // 关掉后在「规划路线」按钮上方冒出提示：只弹一次、只显示 5 秒
              this.showRouteHintOnce();
            })
          }
          .width('100%').padding({ left: 20, right: 8, top: 16, bottom: 8 })

          Divider().strokeWidth(1).color('rgba(255,215,0,0.25)')

          if (this.routePlan.stops.length > 0) {
            Text(`本次路线已打卡 ${this.routeCheckedCount()} / ${this.routePlan.stops.length}`)
              .fontSize(12).fontColor('#FFAAAA').width('100%')
              .padding({ left: 20, top: 8 })
          }

          // 纵向时间线，可滚动
          Scroll() {
            Column() {
              if (this.routePlan.intro !== '') {
                Text(this.routePlan.intro)
                  .fontSize(15).fontColor('#FFD700').fontWeight(FontWeight.Medium)
                  .width('100%').margin({ top: 14, bottom: 4 })
              }
              ForEach(this.routePlan.stops.slice(0, this.routeStopsVisible), (stop: RouteStop, index: number) => {
                Column() {
                  // 无照片的站点（如「最后献花给英雄」）整块不渲染，不留占位
                  if (stop.photo !== '') {
                    Stack() {
                      Image($rawfile(stop.photo))
                        .width('100%').height('100%').objectFit(ImageFit.Cover)
                    }
                    .width('100%').height(240).borderRadius(14)
                    .border({ width: 1, color: 'rgba(255,215,0,0.30)' })
                    .clip(true)
                  }

                  // 照片下方：序号徽章 + 地点名
                  Row() {
                    Text(`${index + 1}`)
                      .fontSize(12).fontColor('#2A0000').fontWeight(FontWeight.Bold)
                      .width(20).height(20).textAlign(TextAlign.Center)
                      .backgroundColor('#FFD700').borderRadius(10)
                    Text(stop.name).fontSize(16).fontColor('#FFD700').fontWeight(FontWeight.Medium)
                      .margin({ left: 8 }).layoutWeight(1)
                    // 与打卡打通：已打卡绿 ✓，未打卡灰 ○
                    if (this.isStopCheckedIn(stop)) {
                      Text('✓ 已打卡').fontSize(11).fontColor('#7CE38B')
                    } else {
                      Text('○ 未打卡').fontSize(11).fontColor('rgba(255,255,255,0.35)')
                    }
                  }
                  .width('100%').margin({ top: 10 })

                  Text(stop.desc)
                    .fontSize(this.chatFontSize).fontColor('#FFE9A8').lineHeight(22)
                    .width('100%').margin({ top: 6 })
                }
                .width('100%').padding(14)
                .backgroundColor('rgba(255,215,0,0.10)')
                .borderRadius(16)
                .border({ width: 1, color: 'rgba(255,215,0,0.25)' })

                // 卡与卡之间的向下箭头；最后一张不画
                if (index < this.routePlan.stops.length - 1) {
                  Image($rawfile('icon_arrow_down.svg')).width(26).height(26)
                    .fillColor('rgba(255,215,0,0.75)').margin({ top: 10, bottom: 10 })
                }
              }, (stop: RouteStop, index: number) =>
                stop.photo + '_' + index.toString() + (this.isStopCheckedIn(stop) ? '_c' : '_n'))
            }
            .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 32 })
          }
          .layoutWeight(1).scrollBar(BarState.Auto)
        }
        .width('100%').height('100%')
        .backgroundColor('#1A0000')
        .position({ x: 0, y: 0 }).zIndex(220)
      }

      if (this.previewVisible && this.previewPixelMap) {
        Column() {
          Image(this.previewPixelMap).objectFit(ImageFit.Contain).width('90%').height('70%').borderRadius(12)
          Button('关闭').margin({ top: 20 }).backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(8).onClick(() => { this.previewVisible = false; })
        }.width('100%').height('100%').backgroundColor('rgba(0,0,0,0.8)').justifyContent(FlexAlign.Center).onClick(() => { this.previewVisible = false; })
      }

      // ---------- 改名弹层 ----------
      if (this.renamingSessionId !== 0) {
        Column() {
          Column() {
            Text('修改对话名称')
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFD700').margin({ bottom: 18 })
            TextInput({ text: this.renameText, placeholder: '请输入新名称' })
              .height(46).backgroundColor('rgba(255,215,0,0.10)').borderRadius(12)
              .fontColor('#FFF8DC').placeholderColor('rgba(255,233,168,0.5)')
              .border({ width: 1, color: 'rgba(255,215,0,0.45)' })
              .onChange((value: string) => { this.renameText = value; })
            Row() {
              Button('取消').layoutWeight(1).height(42).fontSize(15)
                .backgroundColor('rgba(255,215,0,0.16)').fontColor('#FFD700').borderRadius(21)
                .onClick(() => { this.renamingSessionId = 0; })
              Button('保存').layoutWeight(1).height(42).fontSize(15).margin({ left: 10 })
                .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
                .onClick(() => { this.confirmRename(); })
            }.width('100%').margin({ top: 20 })
          }
          .width('86%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(200)
        .onClick(() => { this.renamingSessionId = 0; })
      }

      // ---------- 分享面板（底部滑入式横框） ----------
      if (this.showSharePanel) {
        Column() {
          Column()
            .width('100%').layoutWeight(1).backgroundColor('rgba(0,0,0,0.5)')
            .onClick(() => { this.showSharePanel = false; })
          Column() {
            Text('分享对话').fontSize(16).fontColor('#FFD700').margin({ top: 16, bottom: 4 })
            Text('选择分享方式').fontSize(11).fontColor('#FFAAAA').margin({ bottom: 16 })
            Row() {
              Button('复制对话').layoutWeight(1).height(56).fontSize(13)
                .backgroundColor('rgba(255,215,0,0.10)').fontColor('#FFE9A8').borderRadius(12)
                .border({ width: 1, color: 'rgba(255,215,0,0.3)' })
                .onClick(() => {
                  this.copyTextToClipboard(this.buildShareText(this.shareSessionId));
                  this.showSharePanel = false;
                })
              Button('复制链接').layoutWeight(1).height(56).fontSize(13).margin({ left: 10 })
                .backgroundColor('rgba(255,215,0,0.10)').fontColor('#FFE9A8').borderRadius(12)
                .border({ width: 1, color: 'rgba(255,215,0,0.3)' })
                .onClick(() => { this.copySessionLink(); this.showSharePanel = false; })
              Button('取消').width(64).height(56).fontSize(13).margin({ left: 10 })
                .backgroundColor(Color.Transparent).fontColor('#FFAAAA').borderRadius(12)
                .onClick(() => { this.showSharePanel = false; })
            }.width('100%').padding({ left: 16, right: 16 })
            Text('「复制链接」是 App 深链，对方安装后能看到同样的讲解')
              .fontSize(10).fontColor('rgba(255,170,170,0.7)')
              .margin({ top: 12, bottom: 22 })
          }
          .width('100%').backgroundColor('rgba(42,0,0,0.98)')
          .borderRadius({ topLeft: 20, topRight: 20 })
          .border({ width: { top: 1 }, color: 'rgba(255,215,0,0.4)' })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.End)
        .position({ x: 0, y: 0 }).zIndex(210)
      }

      if (this.showHistory) {
        Column()
          .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.5)')
          .position({ x: 0, y: 0 }).zIndex(105)
          .onClick(() => { this.showHistory = false; })
      }

      Column() {
        Row() {
          Text('历史对话').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFD700').layoutWeight(1)
          Button() { Image($rawfile('icon_new.svg')).width(20).height(20).fillColor('#FFD700') }
          .width(36).height(36).backgroundColor(Color.Transparent)
          .onClick(() => { this.newSession(); this.showHistory = false; })
          Button() {
            Image($rawfile('icon_close_bold.svg')).width(20).height(20).fillColor('#FFD700')
          }
          .width(36).height(36).backgroundColor(Color.Transparent)
          .onClick(() => { this.showHistory = false; })
        }
        .width('100%').padding({ left: 20, right: 8, top: 16, bottom: 8 })

        Divider().strokeWidth(1).color('rgba(255,215,0,0.25)')

        List() {
          ForEach(this.sortedSessions(), (session: SessionData) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(session.title).fontSize(this.chatFontSize).fontColor('#FFF8DC')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                    if (session.isPinned) {
                      Text('📌').fontSize(18).margin({ left: 6 })
                    }
                  }.width('100%').alignItems(VerticalAlign.Center)
                  Text(new Date(session.timestamp).toLocaleString()).fontSize(11).fontColor('#FFAAAA').margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
                // 切换只挂在标题区：⋯ 是它的兄弟节点，点 ⋯ 不会误触发切换
                .onClick(() => { if (this.menuSessionId === 0) this.switchToSession(session); })

                Button() {
                  Text('⋯').fontSize(18).fontColor('#FFD700')
                }
                .width(32).height(32).backgroundColor(Color.Transparent).borderRadius(8)
                .onClick(() => { this.menuSessionId = session.id; })
                .bindMenu(this.sessionMenuBuilder(session), {
                  // 系统菜单底是半透明毛玻璃，透出深红页面后与米黄字对比不足。
                  // 改成不透明暗红 + 关掉毛玻璃，菜单项文字回到「气泡级」可读性。
                  backgroundColor: '#2A0000',
                  backgroundBlurStyle: BlurStyle.NONE,
                  onDisappear: () => { this.menuSessionId = 0; }
                })
              }
              .width('100%').padding(12).borderRadius(10)
              .backgroundColor('rgba(255,215,0,0.08)')
              .border({ width: 1, color: 'rgba(255,215,0,0.2)' })
              .margin({ bottom: 8 })
              // 菜单打开时其余项压暗。用 opacity 而非 backdropBlur —— 长列表下零开销
              .opacity(this.menuSessionId === 0 || this.menuSessionId === session.id ? 1 : 0.35)
            }
          }, (session: SessionData) =>
            session.id.toString() + '_' + session.timestamp.toString() + '_' + session.title +
            (session.isPinned ? '_p' : '_n'))
        }
        .layoutWeight(1).padding({ left: 8, right: 8, top: 8 })

        Row() {
          // 头像：文字头像（昵称首字），点击进入账号管理页
          Stack() {
            if (this.avatarPixelMap !== null) {
              Image(this.avatarPixelMap).width(40).height(40)
                .objectFit(ImageFit.Cover).borderRadius(20)
            } else {
              Circle().width(40).height(40).fill('#8B0000')
              Text(this.userInitial).fontSize(18).fontColor('#FFD700').fontWeight(FontWeight.Bold)
            }
          }
          .width(40).height(40)
          .onClick(() => { router.pushUrl({ url: 'pages/AccountPage' }); })

          Column() {
            Text(this.userName).fontSize(15).fontColor('#FFD700').fontWeight(FontWeight.Medium)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('点击管理账号').fontSize(11).fontColor('#FFAAAA').margin({ top: 2 })
          }
          .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 10 })

          // 设置：进入账号管理页（与点头像等效）
          Button() { Image($rawfile('icon_settings.svg')).width(22).height(22).fillColor('#FFD700') }
          .width(40).height(40).backgroundColor('rgba(255,215,0,0.14)').borderRadius(20)
          .border({ width: 1, color: 'rgba(255,215,0,0.3)' })
          .onClick(() => { router.pushUrl({ url: 'pages/AccountPage' }); })

          // 扫码按钮（自顶栏移入）
          Button() {
            Image($rawfile('icon_scan.svg')).width(22).height(22)
              .fillColor(this.isLoggedIn ? '#FFD700' : 'rgba(255,215,0,0.4)')
          }
          .width(40).height(40).backgroundColor('rgba(255,215,0,0.14)').borderRadius(20)
          .border({ width: 1, color: 'rgba(255,215,0,0.3)' })
          .margin({ left: 6 })
          .onClick(() => { if (this.requireLogin()) this.startScan(); })
        }
        .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 16 })
        .border({ width: { top: 1 }, color: 'rgba(255,215,0,0.25)' })
      }
      .width(320).height('100%').backgroundColor('rgba(26, 0, 0, 0.96)')
      .border({ width: { right: 1 }, color: 'rgba(255, 215, 0, 0.3)' })
      .padding(0)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.6)' })
      .position({ x: 0, y: 0 }).zIndex(110)
      .translate({ x: this.showHistory ? 0 : -320 })
      .animation({ duration: 260, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
  }
}