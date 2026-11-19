import http from '@ohos.net.http';
import buffer from '@ohos.buffer';
import image from '@ohos.multimedia.image';
import { BackendService, RestoreResult } from '../utils/BackendService';
import { MemoryQuantity, MemoryPlacement } from '../model/Memory';

// ==================== 记忆注入开关（测试用：改这里 → 重编译） ====================
/** 数量维度：FULL = 全量塞（对照组） / RECALL = 调度召回 top-K（实验组） */
export const MEMORY_QUANTITY: MemoryQuantity = MemoryQuantity.RECALL;
/** 摆位维度：USER_TAIL(A 拼进 user 尾部) / SYSTEM_SEPARATE(B 独立 system) / SYSTEM_APPEND(C 追加进现有 system) */
export const MEMORY_PLACEMENT: MemoryPlacement = MemoryPlacement.SYSTEM_SEPARATE;

export interface AIMessage {
  role: string;
  content: string;
}

export type RepairProgressCallback = (progress: number, statusText: string) => void;

/* 修复参数：上线前按 restore-service/README.md 第四节那四张对比图定型后再改这里。
 * 服务地址**不在这里** —— 走后端转发，换 GPU 实例只改后端 .env，App 不用重新 Build。 */
const RESTORE_MODEL: string = 'general';
const RESTORE_SCALE: number = 2;
const RESTORE_DENOISE: number = 0.5;
const RESTORE_FACE: boolean = true;

interface RegionSize { width: number; height: number; }
interface PixelRegion { x: number; y: number; size: RegionSize; }
interface PositionArea {
  pixels: ArrayBuffer;
  offset: number;
  stride: number;
  region: PixelRegion;
}

interface RestoreLogMeta {
  faces_found?: number;
  elapsed_ms?: number;
  model?: string;
  /** 请求了上色但实际没上成时为 false；排查「图没带色」时这条最关键 */
  colorize_applied?: boolean;
}

interface AIRequestBody {
  model: string;
  messages: AIMessage[];
  temperature: number;
  max_tokens: number;
}

/**
 * DeepSeek R1 的请求体。刻意不带 temperature / top_p ——
 * reasoner 模型不接受这两个参数，带上没有意义还可能被拒。
 */
interface QuizRequestBody {
  model: string;
  messages: AIMessage[];
  max_tokens: number;
}

function base64EncodeBytes(bytes: Uint8Array): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let result = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a: number = bytes[i]!;
    const b: number = i + 1 < bytes.length ? bytes[i + 1]! : 0;
    const c: number = i + 2 < bytes.length ? bytes[i + 2]! : 0;
    result += chars.charAt(a >> 2);
    result += chars.charAt(((a & 3) << 4) | (b >> 4));
    result += i + 1 < bytes.length ? chars.charAt(((b & 15) << 2) | (c >> 6)) : '=';
    result += i + 2 < bytes.length ? chars.charAt(c & 63) : '=';
  }
  return result;
}

export class AiService {
  public aiUrl: string = 'https://api.siliconflow.cn/v1/chat/completions';
  /**
   * 第三方大模型 API Key（SiliconFlow）。
   * ⚠️ 开源版留空：请填入你自己的 Key，切勿提交真实 Key 到仓库。
   * 更稳妥的做法是把 Key 放到服务端代理，客户端不持有任何第三方密钥。
   */
  public aiKey: string = '';

  // ==================== 本地传统增强（优化版） ====================
  async processLocalTraditional(
    pixelMap: image.PixelMap,
    noiseLevel: number = 0,
    inpaintRadius: number = 0,
    sharpenStrength: number = 0.80,
    claheClipLimit: number = 1.2
  ): Promise<image.PixelMap> {
    try {
      const info = await pixelMap.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const totalPixels: number = width * height;
      const pixelBuffer: ArrayBuffer = new ArrayBuffer(totalPixels * 4);

      await pixelMap.readPixels({
        pixels: pixelBuffer,
        offset: 0,
        stride: width * 4,
        region: { x: 0, y: 0, size: { width: width, height: height } }
      });

      const srcRgba: Uint8Array = new Uint8Array(pixelBuffer);
      const intermediateRgba: Uint8Array = new Uint8Array(totalPixels * 4);

      // 1. 统计亮度直方图 (Y = 0.299R + 0.587G + 0.114B)
      const hist: Uint32Array = new Uint32Array(256);
      for (let i = 0; i < totalPixels; i++) {
        const idx: number = i * 4;
        const yVal: number = Math.round(0.299 * srcRgba[idx] + 0.587 * srcRgba[idx + 1] + 0.114 * srcRgba[idx + 2]);
        hist[Math.min(255, Math.max(0, yVal))]++;
      }

      // 2. 计算 0.5% (黑场) 与 99.5% (白场) 分位点，去除发灰蒙层
      const lowThreshold: number = Math.floor(totalPixels * 0.005);
      const highThreshold: number = Math.floor(totalPixels * 0.995);
      let accum: number = 0;
      let blackPoint: number = 0;
      let whitePoint: number = 255;
      let foundBlack: boolean = false;

      for (let i = 0; i < 256; i++) {
        accum += hist[i];
        if (!foundBlack && accum >= lowThreshold) {
          blackPoint = i;
          foundBlack = true;
        }
        if (accum >= highThreshold) {
          whitePoint = i;
          break;
        }
      }
      if (whitePoint <= blackPoint) {
        whitePoint = 255;
        blackPoint = 0;
      }

      // 3. 构建对比度拉伸 + Gamma 校正查找表 (LUT，Gamma = 0.88)
      const lut: Uint8Array = new Uint8Array(256);
      const gamma: number = 0.88;
      const range: number = whitePoint - blackPoint;
      for (let i = 0; i < 256; i++) {
        let normalized: number = (i - blackPoint) / range;
        normalized = Math.min(1.0, Math.max(0.0, normalized));
        const corrected: number = Math.pow(normalized, gamma);
        lut[i] = Math.min(255, Math.max(0, Math.round(corrected * 255)));
      }

      // 4. 第一遍处理：LUT 映射并累计各通道均值（用于灰度世界白平衡）
      let sumR: number = 0;
      let sumG: number = 0;
      let sumB: number = 0;
      for (let i = 0; i < totalPixels; i++) {
        const idx: number = i * 4;
        const rMapped: number = lut[srcRgba[idx]];
        const gMapped: number = lut[srcRgba[idx + 1]];
        const bMapped: number = lut[srcRgba[idx + 2]];
        intermediateRgba[idx] = rMapped;
        intermediateRgba[idx + 1] = gMapped;
        intermediateRgba[idx + 2] = bMapped;
        intermediateRgba[idx + 3] = srcRgba[idx + 3] > 0 ? srcRgba[idx + 3] : 255;
        sumR += rMapped;
        sumG += gMapped;
        sumB += bMapped;
      }

      const avgR: number = totalPixels > 0 ? sumR / totalPixels : 128;
      const avgG: number = totalPixels > 0 ? sumG / totalPixels : 128;
      const avgB: number = totalPixels > 0 ? sumB / totalPixels : 128;
      const avgGray: number = (avgR + avgG + avgB) / 3.0;

      // 灰度世界增益（限制在 0.7 ~ 1.4 之间，防止极端偏色）
      const gainR: number = Math.min(1.4, Math.max(0.7, avgR > 0 ? avgGray / avgR : 1.0));
      const gainG: number = Math.min(1.4, Math.max(0.7, avgG > 0 ? avgGray / avgG : 1.0));
      const gainB: number = Math.min(1.4, Math.max(0.7, avgB > 0 ? avgGray / avgB : 1.0));

      // 5. 第二遍处理：应用白平衡增益与饱和度增强 (1.15x)
      const satFactor: number = 1.15;
      for (let i = 0; i < totalPixels; i++) {
        const idx: number = i * 4;
        const rWB: number = Math.min(255, Math.max(0, intermediateRgba[idx] * gainR));
        const gWB: number = Math.min(255, Math.max(0, intermediateRgba[idx + 1] * gainG));
        const bWB: number = Math.min(255, Math.max(0, intermediateRgba[idx + 2] * gainB));

        const gray: number = 0.299 * rWB + 0.587 * gWB + 0.114 * bWB;
        intermediateRgba[idx] = Math.min(255, Math.max(0, Math.round(gray + (rWB - gray) * satFactor)));
        intermediateRgba[idx + 1] = Math.min(255, Math.max(0, Math.round(gray + (gWB - gray) * satFactor)));
        intermediateRgba[idx + 2] = Math.min(255, Math.max(0, Math.round(gray + (bWB - gray) * satFactor)));
      }

      // 6. 高性能自适应 USM 锐化 (3x3 空间卷积，带噪点抑制)
      const outRgba: Uint8Array = new Uint8Array(width * height * 4);
      const strength: number = Math.min(1.0, Math.max(0.2, sharpenStrength));
      const noiseThreshold: number = 3.0; // 差值阈值，防止微小颗粒噪点被放大

      for (let y = 0; y < height; y++) {
        const yOffset: number = y * width;
        const topOffset: number = (y > 0 ? y - 1 : y) * width;
        const bottomOffset: number = (y < height - 1 ? y + 1 : y) * width;

        for (let x = 0; x < width; x++) {
          const currIdx: number = (yOffset + x) * 4;
          const leftIdx: number = (yOffset + (x > 0 ? x - 1 : x)) * 4;
          const rightIdx: number = (yOffset + (x < width - 1 ? x + 1 : x)) * 4;
          const topIdx: number = (topOffset + x) * 4;
          const bottomIdx: number = (bottomOffset + x) * 4;

          for (let c = 0; c < 3; c++) {
            const center: number = intermediateRgba[currIdx + c];
            const surroundAvg: number = (
              intermediateRgba[leftIdx + c] +
              intermediateRgba[rightIdx + c] +
              intermediateRgba[topIdx + c] +
              intermediateRgba[bottomIdx + c]
            ) * 0.25;

            const diff: number = center - surroundAvg;
            let sharpened: number = center;
            if (Math.abs(diff) > noiseThreshold) {
              sharpened = center + diff * strength;
            }
            outRgba[currIdx + c] = Math.min(255, Math.max(0, Math.round(sharpened)));
          }
          outRgba[currIdx + 3] = intermediateRgba[currIdx + 3];
        }
      }

      const initOpts: image.InitializationOptions = {
        size: { width: width, height: height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      };
      const newPixelMap: image.PixelMap = await image.createPixelMap(outRgba.buffer, initOpts);
      return newPixelMap;
    } catch (e) {
      console.error('[AiService] processLocalTraditional 失败: ' + (e as Object).toString());
      return pixelMap;
    }
  }

  async processLocalAI(pixelMap: image.PixelMap, scale: number = 2): Promise<image.PixelMap> {
    return await this.bicubicUpscale(pixelMap, scale);
  }

  private async bicubicUpscale(pixelMap: image.PixelMap, scale: number): Promise<image.PixelMap> {
    try {
      const info = await pixelMap.getImageInfo();
      const srcWidth: number = info.size.width;
      const srcHeight: number = info.size.height;
      const pixelBuffer: ArrayBuffer = new ArrayBuffer(srcWidth * srcHeight * 4);
      await pixelMap.readPixels({
        pixels: pixelBuffer,
        offset: 0,
        stride: srcWidth * 4,
        region: { x: 0, y: 0, size: { width: srcWidth, height: srcHeight } }
      });
      const rgba: Uint8Array = new Uint8Array(pixelBuffer);

      const dstWidth: number = Math.round(srcWidth * scale);
      const dstHeight: number = Math.round(srcHeight * scale);
      const outRgba: Uint8Array = new Uint8Array(dstWidth * dstHeight * 4);

      for (let dstY = 0; dstY < dstHeight; dstY++) {
        const srcY: number = dstY / scale;
        for (let dstX = 0; dstX < dstWidth; dstX++) {
          const srcX: number = dstX / scale;
          for (let c = 0; c < 4; c++) {
            const val: number = this.bicubicInterpolate(rgba, srcWidth, srcHeight, srcX, srcY, c);
            outRgba[(dstY * dstWidth + dstX) * 4 + c] = Math.min(255, Math.max(0, Math.round(val)));
          }
        }
      }

      const initOpts: image.InitializationOptions = {
        size: { width: dstWidth, height: dstHeight },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      };
      return await image.createPixelMap(outRgba.buffer, initOpts);
    } catch (e) {
      console.error('[AiService] 双三次插值失败: ' + (e as Object).toString());
      return pixelMap;
    }
  }

  // ==================== 本地增强兜底方法 ====================
  /**
   * 本地传统增强。public：断网预判时 Index 直接调它跳过云端（见 A3 Task 5）。
   * ⚠️ 本函数【不抛异常】—— 内部 catch 后返回原 buffer，调用方不必再包一层 try。
   */
  async localEnhance(imageBuffer: ArrayBuffer, onProgress?: RepairProgressCallback): Promise<ArrayBuffer> {
    if (onProgress) onProgress(10, '开始本地离线修复...');
    try {
      const imgSource = image.createImageSource(imageBuffer);
      const originalPixelMap: image.PixelMap = await imgSource.createPixelMap();
      const originalInfo = await originalPixelMap.getImageInfo();
      let width: number = originalInfo.size.width;
      let height: number = originalInfo.size.height;
      originalPixelMap.release();
      imgSource.release();

      const maxDim: number = 1024;
      let targetWidth: number = width;
      let targetHeight: number = height;
      if (width > maxDim || height > maxDim) {
        const scaleFactor: number = maxDim / Math.max(width, height);
        targetWidth = Math.round(width * scaleFactor);
        targetHeight = Math.round(height * scaleFactor);
      }

      const scaledOpts: image.DecodingOptions = { desiredSize: { width: targetWidth, height: targetHeight } };
      const scaledSource = image.createImageSource(imageBuffer);
      const scaledPixelMap: image.PixelMap = await scaledSource.createPixelMap(scaledOpts);
      scaledSource.release();

      const repairedPixelMap: image.PixelMap = await this.processLocalTraditional(scaledPixelMap, 0, 0, 0.80, 1.2);
      scaledPixelMap.release();

      const imagePacker: image.ImagePacker = image.createImagePacker();
      const packOpts: image.PackingOption = { format: 'image/png', quality: 100 };
      const packedData: ArrayBuffer = await imagePacker.packing(repairedPixelMap, packOpts);
      imagePacker.release();
      repairedPixelMap.release();

      if (onProgress) onProgress(100, '修复完成（本地增强）');
      return packedData;
    } catch (e) {
      console.error('本地修复失败: ' + (e as Object).toString());
      if (onProgress) onProgress(0, '修复失败');
      return imageBuffer;
    }
  }

  // ==================== 主修复入口：优先云端，失败降级本地 ====================
  /**
   * 老照片修复。走**后端**转发到 GPU 修复服务 —— 不直连 GPU 实例：
   * 实例地址随实例变化，而 App 的地址是编译期常量，直连就得每次开 GPU 都改源码重新 Build。
   *
   * backend / appToken 由调用方传入（Index.ets 已持有），这里不再自建连接。
   *
   * @param onCloudOutcome 云端调用【本身】的成败回报（可选）。存在的理由：
   *   本函数的 catch 会把云端失败吞掉、转而返回本地增强的结果，调用方从返回值
   *   分辨不出云端到底通没通。A3 的链路反馈层必须知道真实结果，否则断网时
   *   只点照片修复的用户永远等满 30s 超时（反馈层是瞎的）。
   *   不传此参数时行为与改造前完全一致。
   */
  async repairImage(imageBuffer: ArrayBuffer, backend: BackendService, appToken: string,
    onProgress?: RepairProgressCallback,
    onCloudOutcome?: (ok: boolean, ms: number) => void): Promise<ArrayBuffer> {
    const bytes = new Uint8Array(imageBuffer);
    const base64Image: string = base64EncodeBytes(bytes);

    if (onProgress) onProgress(5, '准备修复...');

    // 单次请求拿不到真实进度，所以按预估时间轴爬升、并在阶段间切文案。
    // 收到响应直接跳到 95% —— 与改造前的做法一致，只是文案贴近真实流水线。
    let pct: number = 12;
    const stageTimer = setInterval(() => {
      pct = pct < 88 ? pct + 3 : 88;
      if (onProgress) {
        const text: string = pct < 45 ? '超分辨与降噪…（Real-ESRGAN）'
          : (pct < 75 ? '人脸修复…（GFPGAN）' : '细节整合…');
        onProgress(pct, text);
      }
    }, 1000);

    const cloudStart: number = Date.now();
    try {
      const result: RestoreResult = await backend.restorePhoto(
        appToken, base64Image, RESTORE_MODEL, RESTORE_SCALE, RESTORE_DENOISE, RESTORE_FACE);
      if (onCloudOutcome) onCloudOutcome(true, Date.now() - cloudStart);
      if (onProgress) onProgress(95, '修复完成，正在下载...');

      // 把服务端回的处理信息打出来。**faces_found = 0 表示这张图没检测到人脸、
      // GFPGAN 实际什么都没做** —— 排障时这一条最有用，别把它当成"人脸已修复"。
      const meta: Object | undefined = result.meta;
      if (meta !== undefined) {
        const m = meta as RestoreLogMeta;
        console.info('[AiService] 修复完成 model=' + (m.model === undefined ? '?' : m.model)
          + ' 人脸=' + (m.faces_found === undefined ? '?' : m.faces_found)
          + ' 上色=' + (m.colorize_applied === undefined ? '?' : m.colorize_applied)
          + ' 耗时=' + (m.elapsed_ms === undefined ? '?' : m.elapsed_ms) + 'ms');
      }

      const repairedBuffer: ArrayBuffer = buffer.from(result.image, 'base64').buffer;
      if (onProgress) onProgress(100, '修复完成（云端）');
      return repairedBuffer;
    } catch (e) {
      if (onCloudOutcome) onCloudOutcome(false, Date.now() - cloudStart);
      console.error('[AiService] 云端修复失败，降级本地增强: ' + (e as Error).message);
      // 降级后必须写明"非 AI" —— 否则本地调对比度的结果会和真修复在界面上分不出来
      if (onProgress) onProgress(50, 'AI 修复不可用，改用本地增强（非 AI）');
      return await this.localEnhance(imageBuffer, onProgress);
    } finally {
      clearInterval(stageTimer);
    }
  }

  // ==================== 本地算法辅助函数 ====================
  private channelAverage(channel: Uint8Array): number {
    let sum: number = 0;
    for (let i = 0; i < channel.length; i++) {
      sum += channel[i];
    }
    return channel.length > 0 ? sum / channel.length : 0;
  }

  private applyGain(channel: Uint8Array, gain: number): Uint8Array {
    const result: Uint8Array = new Uint8Array(channel.length);
    for (let i = 0; i < channel.length; i++) {
      result[i] = Math.min(255, Math.max(0, Math.round(channel[i] * gain)));
    }
    return result;
  }

  private claheChannel(channel: Uint8Array, width: number, height: number, clipLimit: number): Uint8Array {
    const pixelCount: number = width * height;
    const hist: Uint32Array = new Uint32Array(256);
    for (let i = 0; i < pixelCount; i++) {
      hist[channel[i]]++;
    }
    const clipThreshold: number = Math.max(1, Math.floor(pixelCount * 0.01 * clipLimit));
    let excess: number = 0;
    for (let i = 0; i < 256; i++) {
      if (hist[i] > clipThreshold) {
        excess += hist[i] - clipThreshold;
        hist[i] = clipThreshold;
      }
    }
    const redistribution: number = Math.floor(excess / 256);
    const remainder: number = excess % 256;
    for (let i = 0; i < 256; i++) {
      hist[i] += redistribution;
      if (i < remainder) hist[i]++;
    }
    const cdf: Uint32Array = new Uint32Array(256);
    cdf[0] = hist[0];
    for (let i = 1; i < 256; i++) {
      cdf[i] = cdf[i - 1] + hist[i];
    }
    const minCdf: number = cdf[0];
    const denominator: number = pixelCount - minCdf;
    const result: Uint8Array = new Uint8Array(pixelCount);
    for (let i = 0; i < pixelCount; i++) {
      const val: number = channel[i];
      const mapped: number = Math.round(((cdf[val] - minCdf) / denominator) * 255);
      result[i] = Math.min(255, Math.max(0, mapped));
    }
    return result;
  }

  private medianFilter(channel: Uint8Array, width: number, height: number, kernelSize: number): Uint8Array {
    let k: number = kernelSize;
    if (k % 2 === 0) k += 1;
    const result: Uint8Array = new Uint8Array(width * height);
    const half: number = Math.floor(k / 2);
    const window: number[] = [];
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        window.length = 0;
        for (let ky = -half; ky <= half; ky++) {
          const ny: number = y + ky;
          if (ny < 0 || ny >= height) continue;
          for (let kx = -half; kx <= half; kx++) {
            const nx: number = x + kx;
            if (nx < 0 || nx >= width) continue;
            window.push(channel[ny * width + nx]);
          }
        }
        window.sort((a: number, b: number): number => a - b);
        result[y * width + x] = window[Math.floor(window.length / 2)];
      }
    }
    return result;
  }

  private unsharpMask(channel: Uint8Array, width: number, height: number, strength: number): Uint8Array {
    const blurred: Float32Array = new Float32Array(width * height);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        let sum: number = 0;
        let count: number = 0;
        for (let dy = -1; dy <= 1; dy++) {
          const ny: number = y + dy;
          if (ny < 0 || ny >= height) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const nx: number = x + dx;
            if (nx < 0 || nx >= width) continue;
            sum += channel[ny * width + nx];
            count++;
          }
        }
        blurred[y * width + x] = sum / count;
      }
    }
    const result: Uint8Array = new Uint8Array(width * height);
    for (let i = 0; i < width * height; i++) {
      const original: number = channel[i];
      const diff: number = original - blurred[i];
      const sharpened: number = original + strength * diff;
      result[i] = Math.min(255, Math.max(0, Math.round(sharpened)));
    }
    return result;
  }

  private bicubicInterpolate(data: Uint8Array, srcWidth: number, srcHeight: number, x: number, y: number, channel: number): number {
    const x0: number = Math.floor(x);
    const y0: number = Math.floor(y);
    const dx: number = x - x0;
    const dy: number = y - y0;
    let sum: number = 0;
    let weightSum: number = 0;
    for (let m = -1; m <= 2; m++) {
      const yy: number = y0 + m;
      if (yy < 0 || yy >= srcHeight) continue;
      const wy: number = this.cubicWeight(dy - m);
      for (let n = -1; n <= 2; n++) {
        const xx: number = x0 + n;
        if (xx < 0 || xx >= srcWidth) continue;
        const wx: number = this.cubicWeight(dx - n);
        const weight: number = wx * wy;
        const idx: number = (yy * srcWidth + xx) * 4 + channel;
        sum += data[idx] * weight;
        weightSum += weight;
      }
    }
    return weightSum > 0 ? sum / weightSum : 0;
  }

  private cubicWeight(t: number): number {
    const a: number = -0.5;
    const absT: number = Math.abs(t);
    if (absT <= 1) {
      return (a + 2) * absT * absT * absT - (a + 3) * absT * absT + 1;
    } else if (absT < 2) {
      return a * absT * absT * absT - 5 * a * absT * absT + 8 * a * absT - 4 * a;
    }
    return 0;
  }

  // ==================== AI 对话 ====================
  async callAI(prompt: string, grade: string, conversationHistory: AIMessage[],
               memoryContext: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      let systemPrompt: string = '你是小智，松山战役智能讲解员。松山战役是1944年6月4日至9月7日中国远征军在云南龙陵松山对日军松山守备队进行的抗日攻坚战，历时95天，属抗日战争滇西反攻战役，与国共内战无关。你必须严格基于上述史实回答，不得编造具体数字、时间、人名，严禁将松山战役描述为国共内战或解放军与国民党军队之间的作战。';
      systemPrompt += '【地理硬约束】松山位于中国云南省保山市龙陵县腊勐镇（原腊勐乡），在中国境内，紧靠怒江。松山绝不在缅甸境内，与缅北无关。严禁把松山、松山战役纪念碑、子高地、远征军雕塑群等任何松山地点描述为位于缅甸或缅北。注意："滇缅公路""滇西缅北反攻"是历史专有名词，其中的"缅"字仅指公路通向缅甸、战役配合缅北方向，不得据此推断松山在缅甸。';
      systemPrompt += '【作答边界】只回答与松山战役、滇西抗战、松山遗址研学相关的问题。若用户问的是天气、交通、餐饮、住宿、票务等无关话题，直接说明你无法提供这类信息，不要为了显得有帮助而编造或联想任何与松山相关的内容，尤其不要编造地理位置、时间、数字。';
      systemPrompt += '【数字约束】涉及兵力、伤亡、装药量等具体数字时，必须与本次对话提供的知识库上下文完全一致，不得凭记忆修改。';
      if (grade === '小学') systemPrompt += '请用小学生能听懂的语言回答，句子要短，词汇简单，像讲故事一样。';
      else if (grade === '中学') systemPrompt += '请用中学生能理解的语言回答，条理清晰，适当解释历史名词。';
      else systemPrompt += '请用专业而详实的语言回答，深入分析战术和战略。';

      // 摆位 C：记忆追加进现有 system prompt 尾部
      if (MEMORY_PLACEMENT === MemoryPlacement.SYSTEM_APPEND && memoryContext !== '') {
        systemPrompt += '\n\n' + memoryContext;
      }

      const fullMessages: AIMessage[] = [{ role: 'system', content: systemPrompt }];

      // 摆位 B：记忆作为独立 system message。
      // ⚠️ 空记忆不能推 —— 部分 API 会拒绝空 content 的 message。
      if (MEMORY_PLACEMENT === MemoryPlacement.SYSTEM_SEPARATE && memoryContext !== '') {
        fullMessages.push({ role: 'system', content: memoryContext });
      }

      for (let i = 0; i < conversationHistory.length; i++) {
        if (i === conversationHistory.length - 1 && conversationHistory[i].role === 'user') continue;
        fullMessages.push(conversationHistory[i]);
      }

      // 摆位 A：记忆拼进 user message 尾部
      let userContent: string = prompt;
      if (MEMORY_PLACEMENT === MemoryPlacement.USER_TAIL && memoryContext !== '') {
        userContent = memoryContext + '\n\n' + prompt;
      }
      fullMessages.push({ role: 'user', content: userContent });

      const requestBody: AIRequestBody = {
        model: 'Qwen/Qwen2.5-7B-Instruct',
        messages: fullMessages,
        temperature: 0.7,
        max_tokens: 500
      };

      const response = await httpRequest.request(this.aiUrl, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.aiKey}` },
        extraData: JSON.stringify(requestBody),
        connectTimeout: 15000,
        readTimeout: 300000
      });

      if (response.responseCode !== 200) throw new Error('状态码：' + response.responseCode);

      const resultStr = typeof response.result === 'string' ? response.result : buffer.from(response.result as ArrayBuffer).toString();
      const jsonObj = JSON.parse(resultStr) as Record<string, Object>;
      const choices = jsonObj['choices'] as Array<Record<string, Object>>;
      if (choices && choices.length > 0) {
        const firstChoice = choices[0];
        const msg = firstChoice['message'] as Record<string, Object>;
        return (msg['content'] as string).replace(/\*\*/g, '').replace(/#/g, '').trim();
      }
      throw new Error('格式异常');
    } finally {
      httpRequest.destroy();
    }
  }

  // ==================== 报告生成 ====================
  async callAIForSummary(pointsText: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const messages: AIMessage[] = [
        {
          role: 'system',
          content: '你是一个严格的历史报告撰写专家。现在根据一段关于"松山战役"的历史对话内容，提炼出知识点。必须严格遵守：\n' +
            '1. 严禁输出任何开场白、寒暄或引导语，直接输出列表。\n' +
            '2. 严禁解释基础军事概念（如"什么是高地"），只提取对话中提及的具体历史事件、人物、时间、地点。\n' +
            '3. 如果输入中只有基础概念解释而没有实质历史内容，请直接输出"松山战役是滇西抗战的关键战役，发生于1944年，历时95天。"这样的硬核事实作为兜底。时间必须照抄史实，不得推断、合并或改写：松山战役为 1944 年 6 月 4 日至 9 月 7 日，历时 95 天。腾冲（1944 年 9 月）、龙陵（1944 年 11 月）是同期滇西反攻中的其他战役，严禁并入松山战役的起止时间。\n' +
            '4. 输出格式严格要求为：\n1. 知识点一\n2. 知识点二\n3. 知识点三'
        },
        { role: 'user', content: pointsText }
      ];

      const requestBody: AIRequestBody = {
        model: 'Qwen/Qwen2.5-7B-Instruct',
        messages: messages,
        temperature: 0.3,
        max_tokens: 300
      };

      const response = await httpRequest.request(this.aiUrl, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.aiKey}` },
        extraData: JSON.stringify(requestBody),
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (response.responseCode !== 200) throw new Error('状态码：' + response.responseCode);

      const resultStr = typeof response.result === 'string' ? response.result : buffer.from(response.result as ArrayBuffer).toString();
      const jsonObj = JSON.parse(resultStr) as Record<string, Object>;
      const choices = jsonObj['choices'] as Array<Record<string, Object>>;
      if (choices && choices.length > 0) {
        const firstChoice = choices[0];
        const msg = firstChoice['message'] as Record<string, Object>;
        return (msg['content'] as string).replace(/\*\*/g, '').replace(/#/g, '').trim();
      }
      throw new Error('格式异常');
    } finally {
      httpRequest.destroy();
    }
  }

  // ==================== 会话标题生成 ====================
  /**
   * 把用户问题压成一条简短标题。
   * 与 callAIForSummary 分开写：后者的 system prompt 强制输出「1. 知识点」列表格式，
   * 且 readTimeout 是 30 秒，都不适合做标题。
   * 超时/离线由调用方 catch 兜底，这里只负责请求和解析。
   */
  async summarizeTitle(question: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const messages: AIMessage[] = [
        {
          role: 'system',
          content: '你是会话标题生成器。根据用户的问题，输出一个概括该问题的短标题。严格要求：\n' +
            '1. 只输出标题本身，不要任何解释、开场白、前后缀、序号。\n' +
            '2. 不超过 10 个字。\n' +
            '3. 不要加引号、书名号、句号、问号、逗号等任何标点。\n' +
            '4. 不要换行，不要输出多个候选。'
        },
        { role: 'user', content: question }
      ];

      const requestBody: AIRequestBody = {
        model: 'Qwen/Qwen2.5-7B-Instruct',
        messages: messages,
        temperature: 0.2,
        max_tokens: 30
      };

      const response = await httpRequest.request(this.aiUrl, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.aiKey}` },
        extraData: JSON.stringify(requestBody),
        connectTimeout: 4000,
        readTimeout: 5000
      });
      if (response.responseCode !== 200) throw new Error('状态码：' + response.responseCode);

      const resultStr = typeof response.result === 'string' ? response.result : buffer.from(response.result as ArrayBuffer).toString();
      const jsonObj = JSON.parse(resultStr) as Record<string, Object>;
      const choices = jsonObj['choices'] as Array<Record<string, Object>>;
      if (choices && choices.length > 0) {
        const firstChoice = choices[0];
        const msg = firstChoice['message'] as Record<string, Object>;
        return (msg['content'] as string).trim();
      }
      throw new Error('格式异常');
    } finally {
      httpRequest.destroy();
    }
  }

  // ==================== 出题测试（DeepSeek 官方 · R1） ====================
  // 与上面几个方法刻意分开：换了一家服务商、换了一个 key、超时也长得多。
  //
  // R1 是推理模型，两点必须记住：
  //   1. 慢 —— 一次 30 道题实测 1~2 分钟，readTimeout 给到 5 分钟
  //   2. 不支持 response_format: json_object，输出里可能夹着说明文字或 ```json 围栏，
  //      而且思维链被 max_tokens 截断时 content 会直接是空串。
  //   所以这里只负责请求和取正文，JSON 解析与校验全部交给调用方容错处理。
  //   也因为 reasoner 不接受 temperature/top_p，请求体单独定义，不带这两个字段。
  private quizUrl: string = 'https://api.deepseek.com/chat/completions';
  private quizModel: string = 'deepseek-reasoner';
  /**
   * DeepSeek 官方 API Key。以后换 key 只改这一行。
   * ⚠️ 开源版留空：请填入你自己的 Key，切勿提交真实 Key 到仓库。
   */
  private quizKey: string = '';

  /** 调 DeepSeek R1。返回模型正文（未解析）；返回空串表示被截断或格式异常，由调用方决定重试 */
  async callQuizModel(systemPrompt: string, userPrompt: string, maxTokens: number): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const messages: AIMessage[] = [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt }
      ];
      const requestBody: QuizRequestBody = {
        model: this.quizModel,
        messages: messages,
        max_tokens: maxTokens
      };

      const response = await httpRequest.request(this.quizUrl, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.quizKey}` },
        extraData: JSON.stringify(requestBody),
        connectTimeout: 15000,
        readTimeout: 300000
      });
      if (response.responseCode !== 200) throw new Error('状态码：' + response.responseCode);

      const resultStr = typeof response.result === 'string'
        ? response.result
        : buffer.from(response.result as ArrayBuffer).toString('utf-8');
      const jsonObj = JSON.parse(resultStr) as Record<string, Object>;
      const choices = jsonObj['choices'] as Array<Record<string, Object>>;
      if (choices && choices.length > 0) {
        const msg = choices[0]['message'] as Record<string, Object>;
        const content = msg['content'];
        if (content === undefined || content === null) return '';
        return (content as string).trim();
      }
      throw new Error('格式异常');
    } finally {
      httpRequest.destroy();
    }
  }
}