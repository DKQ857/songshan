import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { UserInfo } from './BackendService';

const PREF_NAME: string = 'user_db';
const KEY_TOKEN: string = 'token';
const KEY_USER: string = 'user';
const KEY_REMEMBER: string = 'remember_me';
const KEY_REMEMBERED_USER: string = 'remembered_username';
/** 本地登录标志位。与 token 分开存 —— 见 saveLocalSession 的注释 */
const KEY_LOCAL_SESSION: string = 'local_session';

export class UserManager {
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

  // 保存登录会话（token + 用户信息 + 记住我）
  async saveSession(token: string, user: UserInfo, remember: boolean): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_TOKEN, token);
    await pref.put(KEY_LOCAL_SESSION, false);
    await pref.put(KEY_USER, JSON.stringify(user));
    await pref.put(KEY_REMEMBER, remember);
    if (remember) {
      await pref.put(KEY_REMEMBERED_USER, user.username);
    } else {
      await pref.put(KEY_REMEMBERED_USER, '');
    }
    await pref.flush();
  }

  /**
   * 保存「本地登录」会话。
   *
   * token 刻意存空串：Index.ets 里 6 处上报都是 `if (this.appToken === '') return;`，
   * 空串让它们直接短路 —— 不会发出一批注定 401 的请求，也不拖慢界面。
   *
   * 登录态必须另立标志位：isLoggedIn() 原来是 `token !== ''`，光靠空串会把用户
   * 判成「未登录」——requireLogin() 拦掉受限功能，effectiveGrade() 还会把学段
   * 强制成「大学」（小学/初中/高中全出大学卷）。
   */
  async saveLocalSession(user: UserInfo, remember: boolean): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_TOKEN, '');
    await pref.put(KEY_LOCAL_SESSION, true);
    await pref.put(KEY_USER, JSON.stringify(user));
    await pref.put(KEY_REMEMBER, remember);
    if (remember) {
      await pref.put(KEY_REMEMBERED_USER, user.username);
    } else {
      await pref.put(KEY_REMEMBERED_USER, '');
    }
    await pref.flush();
  }

  // 注册成功后回填用户名
  async saveRememberedUsername(username: string): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_REMEMBERED_USER, username);
    await pref.flush();
  }

  async getToken(): Promise<string> {
    const pref: preferences.Preferences = await this.getPref();
    return await pref.get(KEY_TOKEN, '') as string;
  }

  async getUser(): Promise<UserInfo | null> {
    const pref: preferences.Preferences = await this.getPref();
    const val: string = await pref.get(KEY_USER, '') as string;
    if (val === '') return null;
    try {
      return JSON.parse(val) as UserInfo;
    } catch (e) {
      console.error('用户信息解析失败: ' + (e as Error).message);
      return null;
    }
  }

  // 仅更新本地用户信息（昵称等），不动 token 与「记住我」。
  // 后端没有资料更新接口，所以昵称只在本地生效；重新登录会从后端拉回原值。
  async saveUser(user: UserInfo): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_USER, JSON.stringify(user));
    await pref.flush();
  }

  async logout(): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_TOKEN, '');
    await pref.put(KEY_LOCAL_SESSION, false);
    await pref.put(KEY_USER, '');
    await pref.put(KEY_REMEMBER, false);
    await pref.flush();
  }

  /**
   * 注销账号专用：在 logout() 的基础上，把「记住我」回填的用户名也清掉。
   *
   * logout() 刻意保留 KEY_REMEMBERED_USER（切换账号时预填上一个用户名是合理的），
   * 但账号都删了还预填它的名字就不对了。
   */
  async eraseSession(): Promise<void> {
    await this.logout();
    const pref: preferences.Preferences = await this.getPref();
    await pref.put(KEY_REMEMBERED_USER, '');
    await pref.flush();
  }

  async isLoggedIn(): Promise<boolean> {
    const pref: preferences.Preferences = await this.getPref();
    const token: string = await pref.get(KEY_TOKEN, '') as string;
    const localSession: boolean = await pref.get(KEY_LOCAL_SESSION, false) as boolean;
    // 「记住我」只决定下次是否预填用户名（见 saveSession 里 KEY_REMEMBERED_USER 那两行），
    // 不该参与登录状态判断。以前这里写成 remember && token !== ''，
    // 导致不勾「记住我」登录的用户被当成未登录：功能全被 requireLogin() 拦掉，
    // effectiveGrade() 还会把学段强制成「大学」（切小学也出大学卷）。
    // 本地登录的 token 是空串（刻意为之），所以判据要带上本地会话标志位。
    return token !== '' || localSession;
  }

  async getRememberedUsername(): Promise<string> {
    const pref: preferences.Preferences = await this.getPref();
    return await pref.get(KEY_REMEMBERED_USER, '') as string;
  }
}
