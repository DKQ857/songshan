/**
 * 头像存取工具
 *
 * 相册选图 → 复制进应用沙箱 → 解成 PixelMap。
 *
 * 用系统选择器 PhotoViewPicker，属于「用户主动授权临时 URI」机制，
 * 不需要 READ_IMAGEVIDEO 权限，因此无需修改 module.json5。
 *
 * 🔴 必须复制进沙箱：选择器返回的 URI 是临时授权，App 重启后可能失效。
 * 直接把 URI 存进 preferences，下次启动头像会变空白。
 */
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import picker from '@ohos.file.picker';
import common from '@ohos.app.ability.common';

export class AvatarStore {
  /** 固定文件名，每次更换覆盖同一路径，避免沙箱里堆积旧头像 */
  static readonly FILE_NAME: string = 'avatar.jpg';

  /** 头像在应用沙箱中的固定路径 */
  static pathOf(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + AvatarStore.FILE_NAME;
  }

  /** 从相册选一张图并复制进沙箱，返回沙箱路径；用户取消返回 '' */
  static async pick(context: common.UIAbilityContext): Promise<string> {
    const photoPicker: picker.PhotoViewPicker = new picker.PhotoViewPicker();
    const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
    options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    const result: picker.PhotoSelectResult = await photoPicker.select(options);
    if (result.photoUris.length === 0) return '';
    return AvatarStore.copyToSandbox(context, result.photoUris[0]);
  }

  /** 把可读 URI 复制到固定沙箱路径，返回目标路径 */
  static copyToSandbox(context: common.UIAbilityContext, srcUri: string): string {
    const dest: string = AvatarStore.pathOf(context);
    const srcFile: fs.File = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    const destFile: fs.File = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      fs.copyFileSync(srcFile.fd, destFile.fd);
    } finally {
      fs.closeSync(srcFile);
      fs.closeSync(destFile);
    }
    return dest;
  }

  /**
   * 沙箱路径 → PixelMap，失败返回 null。
   * 刻意不 release ImageSource —— 释放时机不当会让已取出的 PixelMap 变空白，
   * 而头像一个页面生命周期内只加载一次，这点开销可接受。PixelMap 由调用方在
   * aboutToDisappear 里 release。
   */
  static async load(path: string): Promise<image.PixelMap | null> {
    if (path === '') return null;
    try {
      if (!fs.accessSync(path)) return null;
      const src: image.ImageSource = image.createImageSource(path);
      return await src.createPixelMap();
    } catch (e) {
      console.error('读取头像失败: ' + (e as Error).message);
      return null;
    }
  }

  /** 删除沙箱头像文件（「恢复默认头像」用） */
  static remove(path: string): void {
    if (path === '') return;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      console.error('删除头像失败: ' + (e as Error).message);
    }
  }
}
