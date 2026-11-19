/**
 * TtsSpeaker —— 系统语音合成（@hms.ai.textToSpeech）的封装。
 *
 * 替换原先的「5 段预录 MP3 + 关键词猜测」方案：预录只覆盖 5 条固定内容，
 * 范围太窄；TTS 覆盖任意回答。
 *
 * 降级链（与 A3 端云协同同一套路子，但【不依赖也不改动】A3 的能力路由器）：
 *   ① online=0 端侧离线合成   —— 无网可用
 *   ② online=1 云端在线合成   —— ① 建不起来时降级
 *   ③ 都失败 → DEAD，后续调用直接返回，不再重试
 *
 * 【实测】仿真器（HarmonyOS-6.0.31 / x86）只支持 online=1：
 *   online=0 → 1002300005 Create engine failed
 *   online=1 → createEngine/speak/onStart/onComplete/shutdown 全链路成功
 *
 * 任何失败都静默吞掉 —— 调用方不需要 try/catch，播报坏了不影响对话。
 */
import textToSpeech from '@hms.ai.textToSpeech';
import { BusinessError } from '@ohos.base';

/** 引擎状态机 */
enum TtsMode {
  UNKNOWN = 0,   // 还没试过
  OFFLINE = 1,   // 已就绪，端侧离线
  ONLINE = 2,    // 已就绪，云端在线
  DEAD = 3       // 两种模式都建不起来，不再重试
}

const LANG: string = 'zh-CN';
const PERSON: number = 0;

/**
 * speak() 的单次文本上限。
 *
 * 这个数不是猜的：回答由 `AiService.callAI()` 生成，那里写死 `max_tokens: 500`
 * （Qwen2.5-7B-Instruct，见 AiService.ets:582），所以回答长度【有天花板】。
 * 实测 500 token → 555 字（约 1.11 字/token）；Qwen 对常见中文一般 1.4–1.7 字/token，
 * 故天花板约 700–850 字。取 1000，让任何可能的 500-token 输出都能整段念完。
 *
 * ⚠️ 引擎【自身】的字数上限 SDK 未声明（只声明错误码 1002300001「超长或为空」）——
 *    若 1000 被拒，由 speak() 逐级缩短兜底，最差退到 150 字，不会变成没声。
 */
const MAX_CHARS: number = 1000;

/** 引擎拒收超长文本的错误码。SDK 未声明具体字数上限，所以只能事先截断、被拒再退。 */
const ERR_TEXT_OUT_OF_RANGE: number = 1002300001;

/**
 * stop() 同步返回、实际停止是异步的，紧接着 speak() 可能撞上停止窗口。
 * SDK 的 TTS 错误码全集（1002300001/0002/0003/0005/0008/0009/0010）里
 * 【没有】engine busy —— 撞上时不会有可捕获的错误，只会表现为「新答案没被念」。
 * ⚠️ 保守取值，未实测标定。
 */
const STOP_SETTLE_MS: number = 100;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(() => { resolve(); }, ms); });
}

/** 回调只用于记日志 —— 功能上不需要 onStart/onComplete，故留空 */
class TtsListener implements textToSpeech.SpeakListener {
  onStart(requestId: string, response: textToSpeech.StartResponse): void {}
  onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {}
  onStop(requestId: string, response: textToSpeech.StopResponse): void {}
  onError(requestId: string, errorCode: number, errorMessage: string): void {
    console.error('[TTS] onError code=' + errorCode + ' msg=' + errorMessage);
  }
}

export class TtsSpeaker {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private mode: TtsMode = TtsMode.UNKNOWN;
  private seq: number = 0;

  /**
   * 正在飞的那一次 init。
   * prewarm() 与首次 speak() 会同时进 ensureEngine —— 不共享的话 createEngine
   * 会被并发调用两次，建出两个引擎、丢掉一个。欢迎语在 aboutToAppear 里同步发起，
   * 所以这条路径【每次冷启动都会走】。
   */
  private initPromise: Promise<boolean> = Promise.resolve(false);
  private initRunning: boolean = false;

  /**
   * 预热：把 createEngine 的开销从「首次朗读」挪到「App 启动」。失败静默。
   *
   * ⚠️ 只建引擎，【不】朗读任何内容 —— 预热用的发声会在启动时被听见
   *    （录演示视频会录进去），也会绕过静音开关，所以不做。
   */
  async prewarm(): Promise<void> {
    await this.ensureEngine();
  }

  /**
   * 懒加载：首次 speak 时才建引擎，避免拖慢启动。
   * 先试端侧离线，建不起来再降级云端在线。
   */
  private async ensureEngine(): Promise<boolean> {
    if (this.engine !== null) return true;
    if (this.mode === TtsMode.DEAD) return false;

    // 已有一次 init 在飞 —— 复用它，别再建第二个引擎
    if (this.initRunning) return await this.initPromise;

    this.initRunning = true;
    this.initPromise = this.buildEngine();
    try {
      return await this.initPromise;
    } finally {
      this.initRunning = false;
    }
  }

  /** 真正建引擎的部分。下面是改动前 ensureEngine 的 body，一字未改。 */
  private async buildEngine(): Promise<boolean> {
    const offline: textToSpeech.TextToSpeechEngine | null = await this.tryCreate(0);
    if (offline !== null) {
      this.engine = offline;
      this.mode = TtsMode.OFFLINE;
      console.info('[TTS] 引擎就绪：端侧离线');
      return true;
    }

    const online: textToSpeech.TextToSpeechEngine | null = await this.tryCreate(1);
    if (online !== null) {
      this.engine = online;
      this.mode = TtsMode.ONLINE;
      console.info('[TTS] 引擎就绪：云端在线');
      return true;
    }

    // 两种都建不起来 —— 永久跳过，避免每次回答都白试一遍
    this.mode = TtsMode.DEAD;
    console.error('[TTS] 离线与在线均不可用，本次会话不再尝试');
    return false;
  }

  private async tryCreate(online: number): Promise<textToSpeech.TextToSpeechEngine | null> {
    try {
      const params: textToSpeech.CreateEngineParams = {
        language: LANG,
        person: PERSON,
        online: online
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      engine.setListener(new TtsListener());
      return engine;
    } catch (e) {
      const be = e as BusinessError;
      console.error('[TTS] createEngine(online=' + online + ') 失败 code=' + be.code + ' msg=' + be.message);
      return null;
    }
  }

  /** 朗读一段文本。引擎不可用、文本为空、调用出错 —— 一律静默返回。 */
  async speak(text: string): Promise<void> {
    const clean: string = TtsSpeaker.sanitize(text);
    if (clean === '') return;

    const ready: boolean = await this.ensureEngine();
    if (!ready || this.engine === null) return;

    const engine: textToSpeech.TextToSpeechEngine = this.engine;
    // 引擎的字数上限 SDK 未声明（只说 1002300001「超长或为空」）。MAX_CHARS 若被拒就逐级缩短。
    // ⚠️ 重试是安全的：被拒发生在【引擎没有播出任何声音】之后，不会打断正在播放的音频。
    //    代价是长回答可能被截短，但最差等于旧行为（150 那档），不会退化成完全没声。
    const limits: number[] = [MAX_CHARS, 800, 500, 300, 150];
    for (let i = 0; i < limits.length; i++) {
      const slice: string = clean.length <= limits[i] ? clean : clean.substring(0, limits[i]);
      if (slice === '') break;
      try {
        // 上一条还没念完就打断，避免多条叠着念
        if (engine.isBusy()) {
          engine.stop();
          await sleep(STOP_SETTLE_MS);
        }
        this.seq = this.seq + 1;
        const params: textToSpeech.SpeakParams = { requestId: 'ssp-' + Date.now() + '-' + this.seq };
        engine.speak(slice, params);
        return;   // 引擎已受理（不代表播完）
      } catch (e) {
        // ⚠️ 这里【不】标记 DEAD —— speak 阶段的错误多为参数类问题（如超长 1002300001），
        //    标死会让一条长答案永久废掉整个播报。DEAD 只由 createEngine 全败触发。
        const be = e as BusinessError;
        console.error('[TTS] speak 被拒 code=' + be.code + ' len=' + slice.length + ' 第' + (i + 1) + '档');
        // 非超长错误（如语言/音色不支持），缩短也没用，直接放弃
        if (be.code !== ERR_TEXT_OUT_OF_RANGE) return;
      }
    }
    console.error('[TTS] 三档均被拒，本次不播');
  }

  /** 立即停止当前朗读（关闭播报、开始录音时调用） */
  stopSpeaking(): void {
    if (this.engine === null) return;
    try {
      if (this.engine.isBusy()) this.engine.stop();
    } catch (e) {
      console.error('[TTS] stop 失败: ' + JSON.stringify(e));
    }
  }

  /**
   * 释放引擎。页面销毁时调用。
   *
   * ⚠️ mode 复位成 UNKNOWN 而不是 DEAD：aboutToDisappear 触发时实例本应被销毁，
   *    这个值无所谓；但万一实例被复用（生命周期判断万一有误），复位能让下次 speak
   *    重建引擎，而不是永久静音。粘性 DEAD 只留给 ensureEngine 的「两种都建不起来」。
   */
  shutdown(): void {
    if (this.engine !== null) {
      try {
        this.engine.shutdown();
      } catch (e) {
        console.error('[TTS] shutdown 失败: ' + JSON.stringify(e));
      }
      this.engine = null;
    }
    this.mode = TtsMode.UNKNOWN;
  }

  /** 去掉【…】这类卡片前缀（否则会把装饰文字念出来），并把超长文本截断 */
  private static sanitize(text: string): string {
    let s: string = text.trim();
    if (s.startsWith('【')) {
      const end: number = s.indexOf('】');
      if (end > 0) s = s.substring(end + 1).trim();
    }
    if (s.length > MAX_CHARS) {
      // 让截断【可见】。否则只能靠「听着觉得没念完」发现，本轮就是这么绕了两圈的。
      console.error('[TTS] 文本超长被截断 len=' + s.length + ' → ' + MAX_CHARS);
      s = s.substring(0, MAX_CHARS);
    }
    return s;
  }
}
