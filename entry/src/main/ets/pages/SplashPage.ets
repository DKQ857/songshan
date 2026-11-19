import router from '@ohos.router';

@Entry
@Component
struct SplashPage {
  @State opacityValue: number = 0;        // 透明度，初始为0（全透明）
  @State scaleValue: number = 0.8;        // 缩放，初始 0.8 倍

  aboutToAppear() {
    // ========== 可调整参数 ==========
    const animationDuration = 800;         // 淡入+缩放动画时长（毫秒）
    const displayDuration = 2500;          // 总显示时长（毫秒），之后跳转

    // 启动动画
    animateTo({
      duration: animationDuration,
      curve: Curve.EaseOut
    }, () => {
      this.opacityValue = 1;              // 渐变到完全显示
      this.scaleValue = 1;                // 缩放到正常大小
    });

    // 定时判断登录状态并跳转
    setTimeout(() => {
      this.redirect();
    }, displayDuration);
  }

  private redirect(): void {
    router.replaceUrl({ url: 'pages/Index' });
  }

  build() {
    Column() {
      Image($r('app.media.splash_logo'))  // 启动图片（可替换文件名）
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)        // 图片填充方式（Cover: 铺满；Contain: 完整显示）
        .opacity(this.opacityValue)
        .scale({ x: this.scaleValue, y: this.scaleValue })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#8B0000')           // 背景色（图片加载前或留白处可见）
  }
}