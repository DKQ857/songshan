/**
 * 题库：解析与抽题。
 *
 * 题库文件（resources/rawfile/questions.json）的字段与 pages/Index.ets 的 QuizQuestion
 * 同形，只多一个 grade（三档学段：小学 / 中学 / 大学）用于按学段分组。
 *
 * 本模块刻意**不读文件** —— rawfile 读取留在 Index.ets（那里已有验证过的写法），
 * 这里只做「解析 + 抽样」，保持纯函数、无外部依赖。
 */

/** 题库中的一道题：与 Index.ets 的 QuizQuestion 同形，外加 grade */
export interface BankQuestion {
  grade: string;
  kind: string;
  stem: string;
  options: string[];
  accept: string[];
  answer: string;
  explain: string;
}

/** 本次卷子各题型要几道 */
export interface KindWant {
  single: number;
  multi: number;
  judge: number;
  blank: number;
  short: number;
}

/** 某个题型抽不满时的缺口 */
export interface BankShortage {
  kind: string;
  need: number;
  got: number;
}

export interface DrawResult {
  /** 成功抽到的题，按 单选 → 多选 → 判断 → 填空 → 简答 分组排列（与既有界面顺序一致） */
  questions: BankQuestion[];
  /** 缺口；为空数组表示成功 */
  shortages: BankShortage[];
}

/** 单选/多选答案只认 A–E 的大写字母（与判分口径一致） */
function sortLetters(s: string): string {
  const chars: string[] = [];
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c >= 'A' && c <= 'E' && chars.indexOf(c) === -1) chars.push(c);
  }
  chars.sort();
  return chars.join('');
}

function readStr(v: Object): string {
  return v === undefined || v === null ? '' : String(v);
}

function readStrArray(v: Object): string[] {
  const out: string[] = [];
  if (v === undefined || v === null) return out;
  const arr: Array<Object> = v as Array<Object>;
  for (let i = 0; i < arr.length; i++) out.push(String(arr[i]));
  return out;
}

/**
 * 解析题库文本。校验规则与 Index.ets 既有的 parseQuizJson 完全一致 ——
 * 不合格的题在这里就被丢掉并计数，避免它们悄悄吃掉配额。
 *
 * 会先剥掉可能存在的 UTF-8 BOM：BOM 会让 JSON.parse 直接抛错，
 * 而 Windows 记事本存 UTF-8 时可能加上它。
 */
export function parseQuestionBank(text: string): BankQuestion[] {
  let src: string = text;
  if (src.length > 0 && src.charCodeAt(0) === 0xFEFF) src = src.substring(1);

  let raw: Array<Record<string, Object>> = [];
  try {
    raw = JSON.parse(src) as Array<Record<string, Object>>;
  } catch (e) {
    console.error('[QUIZ] 题库 JSON 解析失败: ' + (e as Error).message);
    return [];
  }

  const out: BankQuestion[] = [];
  let dropped: number = 0;
  for (let i = 0; i < raw.length; i++) {
    const item: Record<string, Object> = raw[i];
    const grade: string = readStr(item['grade']).trim();
    const kind: string = readStr(item['kind']).trim();
    const stem: string = readStr(item['stem']).trim();
    const answer: string = readStr(item['answer']).trim();
    const explain: string = readStr(item['explain']);
    const options: string[] = readStrArray(item['options']);
    const accept: string[] = readStrArray(item['accept']);

    if (grade === '' || stem === '' || answer === '') { dropped++; continue; }

    if (kind === 'single') {
      if (options.length !== 4 || answer.length !== 1 || answer < 'A' || answer > 'E') {
        dropped++;
        continue;
      }
      out.push({ grade, kind, stem, options, accept: [], answer, explain });
    } else if (kind === 'multi') {
      // 与出题时对 AI 输出的处理一致：答案重新归一成升序字母串，
      // 所以题库里多选答案写成非升序也能用。
      const sorted: string = sortLetters(answer);
      if (options.length < 4 || options.length > 5 || sorted.length < 2) { dropped++; continue; }
      out.push({ grade, kind, stem, options, accept: [], answer: sorted, explain });
    } else if (kind === 'judge') {
      if (answer !== 'T' && answer !== 'F') { dropped++; continue; }
      out.push({ grade, kind, stem, options: [], accept: [], answer, explain });
    } else if (kind === 'blank') {
      out.push({ grade, kind, stem, options: [], accept, answer, explain });
    } else if (kind === 'short') {
      out.push({ grade, kind, stem, options: [], accept: [], answer, explain });
    } else {
      // kind 不在五种之内（拼错、或用了中文名）—— 与既有解析一致：丢弃
      dropped++;
    }
  }
  if (dropped > 0) console.warn('[QUIZ] 题库有 ' + dropped + ' 道题不合格，已丢弃');
  return out;
}

/** 洗牌（Fisher-Yates）。返回新数组，不改动传入的题池 */
function shuffledCopy(pool: BankQuestion[]): BankQuestion[] {
  const a: BankQuestion[] = pool.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j: number = Math.floor(Math.random() * (i + 1));
    const tmp: BankQuestion = a[i];
    a[i] = a[j];
    a[j] = tmp;
  }
  return a;
}

/**
 * 按学段抽一份卷子：每个题型从自己的题池里随机取够配额。
 *
 * 抽不满**不做部分交付** —— 只返回缺口，由调用方报错。
 * 理由：一份缺题的卷子算出来的分数没有意义，宁可让学生看到明确的失败原因。
 */
export function drawPaper(bank: BankQuestion[], grade: string, want: KindWant): DrawResult {
  const groups: Map<string, BankQuestion[]> = new Map();
  for (let i = 0; i < bank.length; i++) {
    const q: BankQuestion = bank[i];
    if (q.grade !== grade) continue;
    let g: BankQuestion[] | undefined = groups.get(q.kind);
    if (g === undefined) {
      g = [];
      groups.set(q.kind, g);
    }
    g.push(q);
  }

  const order: string[] = ['single', 'multi', 'judge', 'blank', 'short'];
  const needs: number[] = [want.single, want.multi, want.judge, want.blank, want.short];
  const questions: BankQuestion[] = [];
  const shortages: BankShortage[] = [];

  for (let i = 0; i < order.length; i++) {
    const kind: string = order[i];
    const need: number = needs[i];
    if (need <= 0) continue;

    let pool: BankQuestion[] = [];
    const found: BankQuestion[] | undefined = groups.get(kind);
    if (found !== undefined) pool = found;

    const picked: BankQuestion[] = shuffledCopy(pool);
    const take: number = Math.min(need, picked.length);
    for (let j = 0; j < take; j++) questions.push(picked[j]);
    if (take < need) shortages.push({ kind, need, got: take });
  }

  return { questions, shortages };
}
