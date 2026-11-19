/**
 * 账号管理页
 * 自上而下：返回箭头 → 头像+昵称 → 字号调节 → 关于小智 → 切换账号 / 退出登录
 *
 * 字号通过 preferences（xiaozhi_db 的 chat_font_size）持久化，Index.onPageShow 回读生效。
 * 退出登录采用「preferences 信号」模式（与 Index.checkScanParams 同款）：
 * 本页只清凭证并立 pending_logout 标记，真正的状态清理由 Index.onPageShow 复用其 logout() 完成
 * —— 因为 logout() 是 Index 的私有方法，且它清聊天记录那几步（隐私）不能省。
 */
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import image from '@ohos.multimedia.image';
import { UserManager } from '../utils/UserManager';
import { UserInfo } from '../utils/BackendService';
import { AvatarStore } from '../utils/AvatarStore';
import { LocalAuth } from '../utils/LocalAuth';

// 与 Index.ets 共用同一个偏好库
const PREF_STORE_NAME: string = 'xiaozhi_db';
const PREF_KEY_FONT_SIZE: string = 'chat_font_size';
const PREF_KEY_PENDING_LOGOUT: string = 'pending_logout';
const PREF_KEY_AVATAR_PHOTO: string = 'avatar_photo';
const PREF_KEY_CHECKINS: string = 'checkin_records';

/**
 * 打卡记录的形状。**刻意本地声明一份，不从 Index.ets 导入** ——
 * Index.ets 是 @Entry 页面、且没有「页面文件被别的文件 import」的先例，
 * 为 4 个字段在核心文件上开这个口子不划算。字段与 Index.ets:366 的
 * CheckinRecord 一致，那边改了要跟着改（这里只用 userId 做过滤）。
 */
interface CheckinRecord {
  spotKey: string;
  timestamp: number;
  userId: number;
  source: string;
}

/**
 * 按用户隔离的存储 key 前缀 —— 后缀是 username，与 Index.ets 的 userSuffix() 同一约定。
 *
 * ⚠️ 这份清单与 Index.ets 的 sessionsKey / sessionSeqKey / routeKey / routeHintKey /
 *    gradeKeyName / quizKeyName / quizProgressKey 一一对应。那边改了 key 名，这里要跟着改，
 *    否则注销会静默漏删（数据留在磁盘上，同名账号再注册就继承了）。
 *
 * 为什么不走「preferences 信号」让 Index 去删（像 pending_logout 那样）：
 * 注销必须当场完成。立标记交给 Index.onPageShow 处理的话，用户注销后直接杀掉 App，
 * 数据就永远留在磁盘上了。
 */
const USER_SCOPED_KEY_PREFIXES: string[] = [
  'chat_sessions_',
  'chat_session_seq_',
  'route_plan_',
  'route_hint_shown_',
  'grade_choice_',
  'quiz_last_',
  'quiz_progress_'
];

/**
 * 全局单键的长期记忆（Memory.ets 的 PREF_KEY_MEMORY / PREF_KEY_CURRENT_SPOT）。
 *
 * ⚠️ 记忆实际上**没有**按用户隔离（Index.ets:647 用的是 new Memory() 无参构造），
 *    所以清这两个键等于清掉设备上所有账号的记忆。这里仍然清 ——
 *    「账号数据将被删除」是对用户的承诺。多账号互相清的代价留作待办。
 */
const GLOBAL_MEMORY_KEYS: string[] = ['user_memory', 'current_spot'];

const FONT_SIZE_MIN: number = 14;
const FONT_SIZE_MAX: number = 22;
const FONT_SIZE_DEFAULT: number = 16;

/** 无头像照片时的兜底底色（固定，不由用户更改） */
const AVATAR_FALLBACK_COLOR: string = '#8B0000';

/** 「关于小智」弹层正文（静态文案，放在模块级避免在 build() 里拼字符串） */
const ABOUT_TEXT: string = '小智是松山战役智能讲解员，专为滇西抗战红色研学设计。\n\n' +
  '· 内置 194 条松山战役知识，断网也能回答核心问题\n' +
  '· 可按小学 / 中学 / 大学三个学段调整讲解深度\n' +
  '· 支持语音提问、景点自动讲解、研学报告生成\n\n' +
  '松山战役是 1944 年中国远征军用 95 天血战打通滇缅公路的关键一战。\n' +
  '希望小智能帮你记住那些为祖国山河拼过命的年轻士兵。';

@Entry
@Component
struct AccountPage {
  @State userName: string = '未登录';
  @State userInitial: string = '游';
  @State roleLabel: string = '';
  /**
   * 是否已登录（user !== null）。
   * ⚠️ 不能用 userName === '未登录' 判断 —— 已登录但昵称为空的用户，
   *    userName 也会显示「未登录」（见 loadAll 的 display 兜底）。
   */
  @State isLoggedIn: boolean = false;
  /** 是否游客身份。⚠️ 用 role 原始值判断，不用 roleLabel 这个显示文案 */
  @State isTourist: boolean = false;
  @State fontSize: number = FONT_SIZE_DEFAULT;
  @State showFontPanel: boolean = false;
  @State showAbout: boolean = false;
  /** 注销二次确认弹层 */
  @State showEraseConfirm: boolean = false;
  /** 防抖：注销要连着写好几次盘，重复点击会删两遍 */
  @State erasing: boolean = false;
  /** 昵称编辑弹层：'' = 关闭，'name' = 改昵称 */
  @State editMode: string = '';
  @State editName: string = '';
  /** 头像弹层与头像数据；avatarPixelMap 为 null 表示显示兜底色 + 首字 */
  @State showAvatarPanel: boolean = false;
  @State avatarPhoto: string = '';
  @State avatarPixelMap: image.PixelMap | null = null;

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pref: preferences.Preferences | null = null;

  aboutToAppear(): void {
    this.loadAll();
  }

  private async getPref(): Promise<preferences.Preferences> {
    if (this.pref === null) {
      this.pref = await preferences.getPreferences(this.context, PREF_STORE_NAME);
    }
    return this.pref;
  }

  private async loadAll(): Promise<void> {
    const userManager: UserManager = new UserManager(this.context);
    const user: UserInfo | null = await userManager.getUser();
    if (user !== null) {
      const display: string = user.name !== '' ? user.name : user.username;
      this.userName = display !== '' ? display : '未登录';
      this.userInitial = display !== '' ? display.substring(0, 1) : '游';
      this.roleLabel = this.roleText(user.role);
      this.isLoggedIn = true;
      this.isTourist = user.role === 'tourist';
    }
    try {
      const pref: preferences.Preferences = await this.getPref();
      const saved: number = await pref.get(PREF_KEY_FONT_SIZE, FONT_SIZE_DEFAULT) as number;
      if (saved >= FONT_SIZE_MIN && saved <= FONT_SIZE_MAX) {
        this.fontSize = saved;
      }
      const photo: string = await pref.get(PREF_KEY_AVATAR_PHOTO, '') as string;
      if (photo !== '') {
        this.avatarPhoto = photo;
        this.avatarPixelMap = await AvatarStore.load(photo);
      }
    } catch (err) {
      console.error('读取本地配置失败: ' + (err as Error).message);
    }
  }

  private roleText(role: string): string {
    if (role === 'student') return '学生';
    if (role === 'teacher') return '教师';
    if (role === 'tourist') return '游客';
    return '用户';
  }

  /** 字号变更：先更新内存（预览即时生效），再异步落盘 */
  private onFontSizeChange(value: number): void {
    this.fontSize = Math.round(value);
    this.getPref()
      .then((pref: preferences.Preferences) => {
        pref.put(PREF_KEY_FONT_SIZE, this.fontSize);
        pref.flush();
      })
      .catch((e: Error) => {
        console.error('保存字号失败: ' + e.message);
      });
  }

  /** 从相册选头像：即选即存（不走「保存」按钮，避免取消后留下孤儿文件） */
  private async pickAvatar(): Promise<void> {
    try {
      const path: string = await AvatarStore.pick(this.context);
      if (path === '') return;
      this.avatarPhoto = path;
      this.avatarPixelMap = await AvatarStore.load(path);
      await this.saveAvatarPhoto(path);
      promptAction.showToast({ message: '头像已更新' });
    } catch (err) {
      console.error('选择头像失败: ' + (err as Error).message);
      promptAction.showToast({ message: '选择头像失败' });
    }
  }

  /** 恢复默认头像：删沙箱文件 + 清记录 + 回到兜底色 + 昵称首字 */
  private async resetAvatar(): Promise<void> {
    AvatarStore.remove(this.avatarPhoto);
    this.avatarPhoto = '';
    this.avatarPixelMap = null;
    await this.saveAvatarPhoto('');
    promptAction.showToast({ message: '已恢复默认头像' });
  }

  private async saveAvatarPhoto(path: string): Promise<void> {
    try {
      const pref: preferences.Preferences = await this.getPref();
      await pref.put(PREF_KEY_AVATAR_PHOTO, path);
      await pref.flush();
    } catch (err) {
      console.error('保存头像路径失败: ' + (err as Error).message);
    }
  }

  aboutToDisappear(): void {
    if (this.avatarPixelMap !== null) {
      try { this.avatarPixelMap.release(); } catch (e) {}
      this.avatarPixelMap = null;
    }
  }

  /** 打开昵称编辑 */
  private openNameEdit(): void {
    this.editName = this.userName;
    this.editMode = 'name';
  }

  /**
   * 保存资料：昵称写进 user_db（UserManager.saveUser），头像底色写进 xiaozhi_db。
   * 后端没有资料更新接口，昵称仅在本地生效，重新登录会从后端拉回原值。
   */
  private async saveProfile(): Promise<void> {
    if (this.editMode === 'name') {
      const trimmed: string = this.editName.trim();
      if (trimmed === '') {
        promptAction.showToast({ message: '昵称不能为空' });
        return;
      }
      const userManager: UserManager = new UserManager(this.context);
      const user: UserInfo | null = await userManager.getUser();
      if (user !== null) {
        user.name = trimmed;
        await userManager.saveUser(user);
      }
      this.userName = trimmed;
      this.userInitial = trimmed.substring(0, 1);
    }
    this.editMode = '';
    promptAction.showToast({ message: '已保存' });
  }

  /**
   * 游客 / 未登录 → 去登录页。
   *
   * 先清凭证：**游客本质是「已登录的匿名账号」**，不清的话 LoginPage 可能
   * 判定为已登录而直接弹回（与 switchAccount 同理，见其注释）。
   * 未登录态调 logout() 是无害的空操作。
   */
  private async goLogin(): Promise<void> {
    const userManager: UserManager = new UserManager(this.context);
    await userManager.logout();
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  /**
   * 切换账号：清凭证后去登录页。
   * 刻意不立 pending_logout 标记 —— LoginPage 登录成功后会 replaceUrl 出一个全新 Index 实例，
   * 它的 aboutToAppear 会读到新用户；若立了标记，新 Index 的 onPageShow 反而会把刚登录的用户清掉。
   */
  private async switchAccount(): Promise<void> {
    const userManager: UserManager = new UserManager(this.context);
    await userManager.logout();
    promptAction.showToast({ message: '请登录新账号' });
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  /** 退出登录：清凭证 + 立标记，回 Index，由 Index.onPageShow 复用其 logout() 做完整清理 */
  private async doLogout(): Promise<void> {
    const userManager: UserManager = new UserManager(this.context);
    await userManager.logout();
    try {
      const pref: preferences.Preferences = await this.getPref();
      await pref.put(PREF_KEY_PENDING_LOGOUT, '1');
      await pref.flush();
    } catch (err) {
      console.error('写入退出标记失败: ' + (err as Error).message);
    }
    promptAction.showToast({ message: '已退出登录' });
    router.back();
  }

  /**
   * 注销账号：彻底删除账号及其本地数据。
   *
   * 顺序要紧：**先清数据，后清账号与会话**。数据清理要靠 username 拼 key，
   * 而 UserManager.eraseSession() 会把 user 记录清掉 —— 反过来的话就查无此人了。
   */
  private async doEraseAccount(): Promise<void> {
    if (this.erasing) return;
    this.erasing = true;
    const userManager: UserManager = new UserManager(this.context);
    const user: UserInfo | null = await userManager.getUser();
    try {
      if (user !== null) {
        await this.eraseUserScopedData(user.username, user.id);
        const localAuth: LocalAuth = new LocalAuth(this.context);
        await localAuth.deleteAccount(user.username);
      }
      await userManager.eraseSession();
      this.showEraseConfirm = false;
      promptAction.showToast({ message: '账号已注销' });
      router.replaceUrl({ url: 'pages/LoginPage' });
    } catch (err) {
      console.error('[AccountPage] 注销失败: ' + (err as Error).message);
      promptAction.showToast({ message: '注销失败，请重试' });
      this.erasing = false;
    }
  }

  /**
   * 清掉这个账号名下的全部本地数据。
   *
   * 刻意不删的：chat_font_size（字号）、avatar_photo 与沙箱里的 avatar.jpg ——
   * 这三样是**设备级设置**不是账号数据，跟注销无关。后端那份 app_users 记录也删不掉
   * （没有接口），所以「彻底删除」只覆盖本机。
   */
  private async eraseUserScopedData(username: string, userId: number): Promise<void> {
    const pref: preferences.Preferences = await this.getPref();
    for (let i = 0; i < USER_SCOPED_KEY_PREFIXES.length; i++) {
      await pref.delete(USER_SCOPED_KEY_PREFIXES[i] + username);
    }
    // 打卡记录是单键数组，每条带 userId —— 只摘掉本人的，其余人的留着
    const raw: string = await pref.get(PREF_KEY_CHECKINS, '') as string;
    if (raw !== '') {
      const recs: CheckinRecord[] = JSON.parse(raw) as CheckinRecord[];
      const kept: CheckinRecord[] = [];
      for (let i = 0; i < recs.length; i++) {
        if (recs[i].userId !== userId) {
          kept.push(recs[i]);
        }
      }
      await pref.put(PREF_KEY_CHECKINS, JSON.stringify(kept));
    }
    for (let i = 0; i < GLOBAL_MEMORY_KEYS.length; i++) {
      await pref.delete(GLOBAL_MEMORY_KEYS[i]);
    }
    await pref.flush();
  }

  build() {
    Stack() {
      // 深红渐变底，与 Index / LoginPage 保持一致
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#1A0000', 0.0], ['#3D0000', 0.3], ['#5C0000', 0.7], ['#3D0000', 1.0]]
        })

      Column() {
        // ---------- 1. 返回箭头 + 标题 ----------
        Row() {
          Button() {
            Text('←').fontSize(24).fontColor('#FFD700').fontWeight(FontWeight.Bold)
          }
          .width(40).height(40)
          .backgroundColor('rgba(255,215,0,0.14)')
          .borderRadius(20)
          .border({ width: 1, color: 'rgba(255,215,0,0.35)' })
          .onClick(() => { router.back(); })
          Text('账号管理')
            .fontSize(19).fontWeight(FontWeight.Bold).fontColor('#FFD700').layoutWeight(1)
        }
        .width('100%').padding({ left: 8, right: 16, top: 8 })

        // ---------- 2. 头像 + 昵称 + 身份（均可点击编辑） ----------
        Column() {
          Stack() {
            if (this.avatarPixelMap !== null) {
              Image(this.avatarPixelMap).width(84).height(84)
                .objectFit(ImageFit.Cover).borderRadius(42)
            } else {
              Circle().width(84).height(84).fill(AVATAR_FALLBACK_COLOR)
              Text(this.userInitial).fontSize(36).fontColor('#FFD700').fontWeight(FontWeight.Bold)
            }
          }
          .width(84).height(84)
          .onClick(() => { this.showAvatarPanel = true; })

          Text(this.userName).fontSize(20).fontColor('#FFD700').margin({ top: 12 })
            .onClick(() => { this.openNameEdit(); })
          Text(this.roleLabel).fontSize(13).fontColor('#FFAAAA').margin({ top: 4 })
          Text('点头像换头像 · 点昵称改名').fontSize(11)
            .fontColor('rgba(255,170,170,0.7)').margin({ top: 6 })
        }
        .width('100%').padding({ top: 8, bottom: 22 })
        .alignItems(HorizontalAlign.Center)

        // ---------- 3. 字号调节（点击弹层，条目样式与「关于小智」统一） ----------
        Row() {
          Text('字号调节').fontSize(16).fontColor('#FFD700').layoutWeight(1)
          Text(`${this.fontSize} fp`).fontSize(14).fontColor('#FFAAAA').margin({ right: 8 })
          Text('>').fontSize(16).fontColor('#FFAAAA')
        }
        .width('100%').padding(16)
        .backgroundColor('rgba(255,215,0,0.08)').borderRadius(14).margin({ bottom: 10 })
        .onClick(() => { this.showFontPanel = true; })

        // ---------- 4. 关于小智 ----------
        Row() {
          Text('关于小智').fontSize(16).fontColor('#FFD700').layoutWeight(1)
          Text('>').fontSize(16).fontColor('#FFAAAA')
        }
        .width('100%').padding(16)
        .backgroundColor('rgba(255,215,0,0.08)').borderRadius(14)
        .onClick(() => { this.showAbout = true; })

        Blank()

        // ---------- 5. 账号操作 ----------
        // 仅「已登录的实名账号」才给切换/退出；游客与未登录只有一个「登录」出口。
        Column() {
          if (this.isLoggedIn && !this.isTourist) {
            // Button 一旦带子组件，.fontColor() 就不再作用于文字，文字颜色必须写在 Text 上
            Button() {
              Row() {
                Image($rawfile('icon_switch.svg')).width(20).height(20).fillColor('#FFD700')
                Text('切换账号').fontSize(16).fontColor('#FFD700').margin({ left: 8 })
              }.alignItems(VerticalAlign.Center)
            }
            .width('100%').height(48)
            .backgroundColor('rgba(255,215,0,0.16)').borderRadius(24)
            .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
            .onClick(() => { this.switchAccount(); })
            Button() {
              Row() {
                // 该图标视框 30×30、图形几乎铺满，同尺寸下会比 icon_switch(24 视框) 大一圈，
                // 缩到 17 让两者的实际绘制宽度对齐（19.7 → 16.7，对面上是 16.8）
                Image($rawfile('icon_logout.svg')).width(17).height(17).fillColor('#FFF8DC')
                Text('退出登录').fontSize(16).fontColor('#FFF8DC').margin({ left: 8 })
              }.alignItems(VerticalAlign.Center)
            }
            .width('100%').height(48)
            .backgroundColor('#8B0000').borderRadius(24)
            .margin({ top: 10 })
            .onClick(() => { this.doLogout(); })

            // 注销 = 彻底删号，与「退出登录」不是一回事，用描边区分：
            // 填色按钮是"安全的主操作"的视觉语言，破坏性操作不该用它。
            // 放在退出登录下方：危险操作离拇指热区更远。
            Button('注销账号')
              .width('100%').height(44).fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor('#FF8A8A')
              .borderRadius(22)
              .border({ width: 1, color: 'rgba(255,138,138,0.55)' })
              .margin({ top: 10 })
              .onClick(() => { this.showEraseConfirm = true; })
          } else {
            Button('登录')
              .width('100%').height(48).fontSize(16)
              .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(24)
              .onClick(() => { this.goLogin(); })
          }
        }
        .width('100%').padding({ bottom: 20 })
      }
      .width('100%').height('100%').padding({ left: 16, right: 16 })

      // ---------- 「关于小智」弹层（overlay 模式，与预览/语音面板同款） ----------
      if (this.showAbout) {
        Column() {
          Column() {
            Text('关于小智')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFD700').margin({ bottom: 14 })
            Text(ABOUT_TEXT)
              .fontSize(15).fontColor('#FFE9A8').lineHeight(24).textAlign(TextAlign.Start)
            Button('知道了').width('60%').height(42).fontSize(15).margin({ top: 20 })
              .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
              .onClick(() => { this.showAbout = false; })
          }
          .width('84%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(200)
        .onClick(() => { this.showAbout = false; })
      }

      // ---------- 头像弹层：放大头像 + 更换头像 + 恢复默认头像 ----------
      if (this.showAvatarPanel) {
        Column() {
          Column() {
            Text('头像').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFD700').margin({ bottom: 16 })

            // 放大的头像：有照片显示照片，否则兜底色 + 昵称首字
            Stack() {
              if (this.avatarPixelMap !== null) {
                Image(this.avatarPixelMap).width(120).height(120)
                  .objectFit(ImageFit.Cover).borderRadius(60)
              } else {
                Circle().width(120).height(120).fill(AVATAR_FALLBACK_COLOR)
                Text(this.userInitial).fontSize(52).fontColor('#FFD700').fontWeight(FontWeight.Bold)
              }
            }
            .width(120).height(120)
            .border({ width: 2, color: 'rgba(255,215,0,0.6)' })
            .borderRadius(60)

            // 紧贴放大头像正下方
            Button('更换头像').width('70%').height(42).fontSize(15).margin({ top: 16 })
              .backgroundColor('rgba(255,215,0,0.16)').fontColor('#FFD700').borderRadius(21)
              .border({ width: 1, color: 'rgba(255,215,0,0.55)' })
              .onClick(() => { this.pickAvatar(); })

            if (this.avatarPhoto !== '') {
              Button('恢复默认头像').width('70%').height(38).fontSize(13).margin({ top: 10 })
                .backgroundColor(Color.Transparent).fontColor('#FFAAAA').borderRadius(19)
                .onClick(() => { this.resetAvatar(); })
            }

            Button('完成').width('60%').height(42).fontSize(15).margin({ top: 18 })
              .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
              .onClick(() => { this.showAvatarPanel = false; })
          }
          .width('86%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(220)
        .onClick(() => { this.showAvatarPanel = false; })
      }

      // ---------- 昵称编辑弹层 ----------
      if (this.editMode !== '') {
        Column() {
          Column() {
            Text('修改昵称')
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFD700').margin({ bottom: 18 })

            TextInput({ text: this.editName, placeholder: '请输入新昵称' })
              .height(46).backgroundColor('rgba(255,215,0,0.10)').borderRadius(12)
              .fontColor('#FFF8DC').placeholderColor('rgba(255,233,168,0.5)')
              .border({ width: 1, color: 'rgba(255,215,0,0.45)' })
              .onChange((value: string) => { this.editName = value; })

            Row() {
              Button('取消').layoutWeight(1).height(42).fontSize(15)
                .backgroundColor('rgba(255,215,0,0.16)').fontColor('#FFD700').borderRadius(21)
                .onClick(() => { this.editMode = ''; })
              Button('保存').layoutWeight(1).height(42).fontSize(15).margin({ left: 10 })
                .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
                .onClick(() => { this.saveProfile(); })
            }
            .width('100%').margin({ top: 20 })
          }
          .width('84%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(210)
        .onClick(() => { this.editMode = ''; })
      }

      // ---------- 字号调节弹层 ----------
      if (this.showFontPanel) {
        Column() {
          Column() {
            Text('字号调节')
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFD700').margin({ bottom: 6 })
            Text('调整后立即生效，聊天与试卷文字同步变化')
              .fontSize(12).fontColor('rgba(255,170,170,0.8)')

            // 实时预览：直接用当前字号渲染示例文本
            Text('松山战役是 1944 年中国远征军打通滇缅公路的关键一战。')
              .fontSize(this.fontSize).fontColor('#FFE9A8').lineHeight(this.fontSize * 1.6)
              .width('100%').padding(12).margin({ top: 16, bottom: 4 })
              .backgroundColor('rgba(255,215,0,0.10)').borderRadius(10)

            Row() {
              Text('小').fontSize(12).fontColor('#FFAAAA')
              Slider({ value: this.fontSize, min: FONT_SIZE_MIN, max: FONT_SIZE_MAX, step: 1 })
                .layoutWeight(1)
                .selectedColor('#FFD700')
                .trackColor('rgba(255,215,0,0.25)')
                .onChange((value: number, mode: SliderChangeMode) => { this.onFontSizeChange(value); })
              Text('大').fontSize(18).fontColor('#FFAAAA')
            }
            .width('100%').margin({ top: 4 })

            Row() {
              Text('当前 ' + this.fontSize + ' fp').fontSize(13).fontColor('#FFAAAA').layoutWeight(1)
              Button('完成').width('40%').height(42).fontSize(15)
                .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
                .onClick(() => { this.showFontPanel = false; })
            }
            .width('100%').margin({ top: 18 }).alignItems(VerticalAlign.Center)
          }
          .width('84%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,215,0,0.5)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(205)
        .onClick(() => { this.showFontPanel = false; })
      }

      // ---------- 注销二次确认弹层 ----------
      if (this.showEraseConfirm) {
        Column() {
          Column() {
            Text('注销账号')
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FF8A8A').margin({ bottom: 14 })
            Text('确定注销账号？此操作不可恢复，账号数据将被删除。')
              .fontSize(15).fontColor('#FFE9A8').lineHeight(24).width('100%')

            Row() {
              Button('取消').layoutWeight(1).height(42).fontSize(15)
                .backgroundColor('rgba(255,215,0,0.16)').fontColor('#FFD700').borderRadius(21)
                .onClick(() => { this.showEraseConfirm = false; })
              Button('确认注销').layoutWeight(1).height(42).fontSize(15).margin({ left: 10 })
                .backgroundColor('#8B0000').fontColor('#FFF8DC').borderRadius(21)
                .onClick(() => { this.doEraseAccount(); })
            }
            .width('100%').margin({ top: 20 })
          }
          .width('84%').padding(22)
          .backgroundColor('#2A0000').borderRadius(16)
          .border({ width: 1, color: 'rgba(255,138,138,0.6)' })
        }
        .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.72)')
        .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 }).zIndex(230)
        .onClick(() => { this.showEraseConfirm = false; })
      }
    }
    .width('100%')
    .height('100%')
  }
}
