import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { UserManager } from '../utils/UserManager';
import { UserInfo } from '../utils/BackendService';
import { LocalAuth } from '../utils/LocalAuth';

@Entry
@Component
struct LoginPage {
  @State username: string = '';
  @State password: string = '';
  @State rememberMe: boolean = false;

  aboutToAppear(): void {
    this.loadRememberedUsername();
  }

  private async loadRememberedUsername(): Promise<void> {
    const userManager: UserManager = new UserManager(getContext(this) as common.UIAbilityContext);
    const name: string = await userManager.getRememberedUsername();
    if (name !== '') this.username = name;
  }

  /**
   * 登录走本地账号体系，不请求后端。
   *
   * 复赛评委装在 HAP 里直接跑，登录不能再依赖公网后端 —— 后端在腾讯云，
   * 现场网络和实例状态都不由我们控制，登录失败对评委就是「App 坏了」。
   * 后端仍用于教师端数据汇聚，但那不参与放行。
   */
  private async handleLogin(): Promise<void> {
    if (this.username.trim() === '') {
      promptAction.showToast({ message: '请输入用户名' });
      return;
    }
    if (this.password === '') {
      promptAction.showToast({ message: '请输入密码' });
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const localAuth: LocalAuth = new LocalAuth(context);
    const userManager: UserManager = new UserManager(context);
    let user: UserInfo | null = null;
    try {
      await localAuth.ensureSeeded();
      user = await localAuth.verify(this.username.trim(), this.password);
    } catch (e) {
      console.error('[LoginPage] 本地登录异常: ' + (e as Error).message);
      promptAction.showToast({ message: '登录失败，请重试' });
      return;
    }
    if (user === null) {
      promptAction.showToast({ message: '用户名或密码错误' });
      return;
    }
    // token 存空串：Index.ets 的上报会据此短路；登录态靠本地会话标志位（见 UserManager）
    await userManager.saveLocalSession(user, this.rememberMe);
    promptAction.showToast({ message: '登录成功' });
    router.replaceUrl({ url: 'pages/Index' });
  }

  private goBack(): void {
    if (Number(router.getLength()) > 1) {
      router.back();
    } else {
      router.replaceUrl({ url: 'pages/Index' });
    }
  }

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
          Text('松山滇西抗战').fontSize(30).fontWeight(FontWeight.Bold).fontColor('#FFD700')
            .shadow({ radius: 8, color: 'rgba(255,215,0,0.5)' })
          Text('红色研学智能平台').fontSize(16).fontColor('#FFD700').margin({ top: 6 }).letterSpacing(4)
          Text('账号登录').fontSize(13).fontColor('#FFAAAA').margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 80, bottom: 30 })

        Column() {
          TextInput({ text: this.username, placeholder: '请输入用户名' })
            .height(46).fontSize(16).backgroundColor(Color.White).borderRadius(10)
            .onChange((value: string) => { this.username = value; })

          TextInput({ text: this.password, placeholder: '请输入密码（不少于6位）' })
            .type(InputType.Password)
            .height(46).fontSize(16).backgroundColor(Color.White).borderRadius(10)
            .margin({ top: 14 })
            .onChange((value: string) => { this.password = value; })

          Row() {
            Toggle({ type: ToggleType.Checkbox, isOn: this.rememberMe })
              .selectedColor('#FFD700')
              .onChange((isOn: boolean) => { this.rememberMe = isOn; })
            Text('记住我').fontSize(14).fontColor('#2E0000').margin({ left: 6 })
          }
          .width('100%')
          .margin({ top: 14 })
          .alignItems(VerticalAlign.Center)

          Button('登 录')
            .width('100%').height(46).fontSize(17).fontWeight(FontWeight.Bold)
            .backgroundColor('#8B0000').fontColor(Color.White).borderRadius(10)
            .margin({ top: 24 })
            .shadow({ radius: 8, color: 'rgba(139,0,0,0.5)' })
            .onClick(() => { this.handleLogin(); })

          Button('没有账号？去注册')
            .width('100%').height(40).fontSize(14)
            .backgroundColor(Color.Transparent).fontColor('#FFD700').borderRadius(10)
            .margin({ top: 8 })
            .onClick(() => { router.pushUrl({ url: 'pages/RegisterPage' }); })
        }
        .width('86%')
        .padding(24)
        .backgroundColor('rgba(255,248,220,0.92)')
        .borderRadius(20)
        .shadow({ radius: 20, color: 'rgba(0,0,0,0.3)' })
      }
      .width('100%')
      .height('100%')

      Button('← 返回')
        .height(36).padding({ left: 16, right: 16 }).fontSize(14)
        .backgroundColor('rgba(0,0,0,0.25)').fontColor('#FFD700').borderRadius(18)
        .position({ x: 16, y: 48 })
        .onClick(() => { this.goBack(); })
    }
    .width('100%')
    .height('100%')
  }
}
