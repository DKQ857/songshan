import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { UserInfo } from './BackendService';

/**
 * 纯本地账号体系（离线登录）。
 *
 * 为什么存在：复赛评委装在 HAP 里直接跑，登录不能再依赖公网后端 ——
 * 后端在腾讯云，现场网络和实例状态都不是我们能控的，登录失败对评委就是「App 坏了」。
 *
 * 与后端的关系：本地账号只用来放行 App 内的受限功能。/app/* 上报会因
 * appToken 为空串而在 Index.ets 里短路（见 UserManager.saveLocalSession 的注释）。
 */

const PREF_NAME: string = 'local_auth';
const KEY_ACCOUNTS: string = 'accounts';

/** 预置演示账号：评委拿到 HAP 无需注册、无需联网即可登录 */
export const DEMO_USERNAME: string = 'judge';
export const DEMO_PASSWORD: string = 'demo1234';

interface LocalAccount {
  username: string;
  passwordHash: string;
  role: string;
  name: string;
  student_no: string;
  school: string;
  class_name: string;
  grade_level: string;
}

export interface LocalRegisterInput {
  username: string;
  password: string;
  role: string;
  name?: string;
  student_no?: string;
  school?: string;
  class_name?: string;
  grade_level?: string;
}

/**
 * 口令摘要。
 *
 * **这不是加密哈希**，只是防「明文躺在 preferences 里被一眼读走」的混淆级处理。
 * 演示账号的口令本来就要写进演示材料（评委必须知道），加密哈希在这里没有意义；
 * 真实风险模型是「设备在自己手上」，不值得为它引入 @ohos.security.cryptoFramework
 * 及随之而来的编译风险。
 * 日后要收紧：把本函数换成 cryptoFramework 的 SHA-256 + 随机盐即可，调用方不用动。
 */
function hashPassword(password: string, salt: string): string {
  const input: string = salt + '#' + password;
  let forward: number = 5381;
  for (let i = 0; i < input.length; i++) {
    forward = (((forward << 5) + forward) ^ input.charCodeAt(i)) | 0;
  }
  let backward: number = 52711;
  for (let i = input.length - 1; i >= 0; i--) {
    backward = (((backward << 5) + backward) ^ input.charCodeAt(i)) | 0;
  }
  return (forward >>> 0).toString(16) + '-' + (backward >>> 0).toString(16);
}

/**
 * 本地账号的 id。
 *
 * 不能给 0 —— Index.ets 里 0 是「游客 / 未登录」，会话列表和路线都按 user_id 隔离，
 * 全给 0 会让所有本地账号共用同一个数据桶。取负数避开后端自增 id。
 */
function localUserId(username: string): number {
  let h: number = 5381;
  for (let i = 0; i < username.length; i++) {
    h = (((h << 5) + h) ^ username.charCodeAt(i)) | 0;
  }
  const v: number = Math.abs(h % 1000000000);
  return v === 0 ? -1 : -v;
}

export class LocalAuth {
  private pref: preferences.Preferences | null = null;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private async getPref(): Promise<preferences.Preferences> {
    if (this.pref === null) {
      this.pref = await preferences.getPreferences(this.context, PREF_NAME);
    }
    return this.pref;
  }

  private async readAccounts(): Promise<LocalAccount[]> {
    const pref: preferences.Preferences = await this.getPref();
    const val: string = await pref.get(KEY_ACCOUNTS, '') as string;
    if (val === '') return [];
    try {
      return JSON.parse(val) as LocalAccount[];
    } catch (e) {
      console.error('[LocalAuth] 账号表解析失败: ' + (e as Error).message);
      return [];
    }
  }

  private async writeAccounts(accounts: LocalAccount[]): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_ACCOUNTS, JSON.stringify(accounts));
    await pref.flush();
  }

  /** 写入预置演示账号。幂等：已存在就跳过，评委改过的密码不会被覆盖 */
  async ensureSeeded(): Promise<void> {
    const accounts: LocalAccount[] = await this.readAccounts();
    for (let i = 0; i < accounts.length; i++) {
      if (accounts[i].username === DEMO_USERNAME) return;
    }
    const demo: LocalAccount = {
      username: DEMO_USERNAME,
      passwordHash: hashPassword(DEMO_PASSWORD, DEMO_USERNAME),
      role: 'student',
      name: '演示评委',
      student_no: 'JUDGE',
      school: '演示学校',
      class_name: '演示班级',
      grade_level: '初中'
    };
    accounts.push(demo);
    await this.writeAccounts(accounts);
    console.info('[LocalAuth] 已写入预置演示账号: ' + DEMO_USERNAME);
  }

  /** 校验通过返回用户信息，失败返回 null */
  async verify(username: string, password: string): Promise<UserInfo | null> {
    const accounts: LocalAccount[] = await this.readAccounts();
    for (let i = 0; i < accounts.length; i++) {
      const a: LocalAccount = accounts[i];
      if (a.username !== username) continue;
      if (hashPassword(password, a.username) !== a.passwordHash) return null;
      const user: UserInfo = {
        id: localUserId(a.username),
        username: a.username,
        role: a.role,
        name: a.name,
        student_no: a.student_no,
        school: a.school,
        class_name: a.class_name,
        grade_level: a.grade_level
      };
      return user;
    }
    return null;
  }

  /** 返回 null 表示成功；否则返回给用户看的错误文案 */
  async register(input: LocalRegisterInput): Promise<string | null> {
    const accounts: LocalAccount[] = await this.readAccounts();
    for (let i = 0; i < accounts.length; i++) {
      if (accounts[i].username === input.username) return '用户名已存在';
    }
    const account: LocalAccount = {
      username: input.username,
      passwordHash: hashPassword(input.password, input.username),
      role: input.role,
      name: input.name === undefined ? '' : input.name,
      student_no: input.student_no === undefined ? '' : input.student_no,
      school: input.school === undefined ? '' : input.school,
      class_name: input.class_name === undefined ? '' : input.class_name,
      grade_level: input.grade_level === undefined ? '' : input.grade_level
    };
    accounts.push(account);
    await this.writeAccounts(accounts);
    return null;
  }

  /**
   * 删除本地账号。返回 true 表示确实删掉了一个，false 表示本来就没有。
   *
   * ⚠️ 对预置演示账号不做保护：judge 被删掉后，下次登录时 ensureSeeded() 会把它补回来，
   *    所以注销 judge 不会把演示环境搞坏（见 ensureSeeded 的幂等逻辑）。
   */
  async deleteAccount(username: string): Promise<boolean> {
    const accounts: LocalAccount[] = await this.readAccounts();
    const kept: LocalAccount[] = [];
    let removed: boolean = false;
    for (let i = 0; i < accounts.length; i++) {
      if (accounts[i].username === username) {
        removed = true;
      } else {
        kept.push(accounts[i]);
      }
    }
    if (removed) {
      await this.writeAccounts(kept);
    }
    return removed;
  }
}
