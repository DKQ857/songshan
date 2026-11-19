import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import preferences from '@ohos.data.preferences';
import { BusinessError } from '@ohos.base';
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';

const PREF_NAME: string = 'scan_params';

export default class EntryAbility extends UIAbility {
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleDeepLink(want);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleDeepLink(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/SplashPage', (err, data) => {
      if (err.code) {
        console.error('Failed to load the content. Cause: ' + JSON.stringify(err));
        return;
      }
      console.info('Succeeded in loading the content. Data: ' + JSON.stringify(data));

      // 设置键盘避让模式为 RESIZE：键盘弹出时压缩窗口高度，输入框紧贴键盘上方
      windowStage.getMainWindow().then((win: window.Window) => {
        win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      }).catch((e: BusinessError) => {
        console.error('设置键盘避让模式失败: ' + e.message);
      });
    });
  }

  private async handleDeepLink(want: Want): Promise<void> {
    try {
      // 确保 uri 存在且为字符串
      const uri: string = want?.uri ?? '';
      if (uri === '') return;

      const queryIndex: number = uri.indexOf('?');
      if (queryIndex === -1) return;

      const queryString: string = uri.substring(queryIndex + 1);
      const pairs: string[] = queryString.split('&');
      let point: string = '';
      let question: string = '';

      for (let i = 0; i < pairs.length; i++) {
        const pair: string[] = pairs[i].split('=');
        if (pair.length === 2) {
          const key: string = decodeURIComponent(pair[0]);
          const value: string = decodeURIComponent(pair[1]);
          if (key === 'point') point = value;
          else if (key === 'question') question = value;
        }
      }

      const context = this.context;
      const pref = await preferences.getPreferences(context, PREF_NAME);
      if (point !== '') {
        await pref.put('scanPoint', point);
        // 热启动快路径：同步写 AppStorage，Index 的 @StorageLink @Watch 立刻响应。
        // 不能只靠上面的 preferences —— onNewWant 没有 await handleDeepLink，
        // onPageShow 会抢在 put/flush 落盘之前读，表现为「App 已运行时扫码没反应」。
        AppStorage.setOrCreate('pendingSpot', point);
      }
      if (question !== '') {
        await pref.put('scanQuestion', question);
      }
      await pref.flush();
    } catch (e) {
      console.error('处理DeepLink失败: ' + (e as Error).message);
    }
  }
}