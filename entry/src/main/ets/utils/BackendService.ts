import http from '@ohos.net.http';
import buffer from '@ohos.buffer';

// 后端基础地址。开源版默认指向本机后端，请按自己的部署环境修改。
// 模拟器访问宿主机用 10.0.2.2；真机调试请填局域网 IP 或你的公网地址。
const BASE_URL: string = 'http://127.0.0.1:3000/api/v1';

/**
 * 后端可空文本字段的安全读取。
 * 不能直接 String(x) —— 后端返回 null 时会变成字符串 'null'，那是个能显示出来的假值。
 */
function readNullableText(value: Object): string {
  if (value === undefined || value === null) return '';
  return String(value);
}

export interface UserInfo {
  id: number;
  username: string;
  role: string;
  name: string;
  student_no: string;
  school: string;
  class_name: string;
  /** 学段：小学 / 初中 / 高中 / 大学。老账号或非学生为空串 */
  grade_level: string;
}


export interface RegisterData {
  username: string;
  password: string;
  role: string;
  name?: string;
  student_no?: string;
  school?: string;
  class_name?: string;
  grade_level?: string;
}

export interface LoginData {
  username: string;
  password: string;
}

export interface LoginResult {
  token: string;
  user: UserInfo;
}

/** 老照片修复的返回。image 是 base64；meta 仅用于日志与排障 */
export interface RestoreResult {
  image: string;
  meta?: Object;
}

export class BackendService {
  private async request(method: http.RequestMethod, path: string, body: object | null, token: string): Promise<Record<string, Object>> {
    const httpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json' };
      if (token !== '') {
        header['Authorization'] = 'Bearer ' + token;
      }
      const response = body === null
        ? await httpRequest.request(BASE_URL + path, {
            method: method, header: header, connectTimeout: 30000, readTimeout: 30000
          })
        : await httpRequest.request(BASE_URL + path, {
            method: method, header: header, extraData: JSON.stringify(body), connectTimeout: 60000, readTimeout: 30000
          });
      const status: number = response.responseCode;
      const resultStr: string = typeof response.result === 'string'
        ? response.result
        : buffer.from(response.result as ArrayBuffer).toString('utf-8');
      const json: Record<string, Object> = resultStr === '' ? {} : JSON.parse(resultStr) as Record<string, Object>;
      if (status >= 200 && status < 300) {
        return json;
      }
      const errMsg: string = json['error'] ? String(json['error']) : '请求失败(' + status + ')';
      throw new Error(errMsg);
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 老照片修复：交给后端，后端再转发到 GPU 修复服务。
   *
   * 刻意不复用 request() —— 它的 readTimeout 是 30 秒，而修复在慢卡上要 60 秒以上。
   * 也刻意不让 App 直连 GPU 实例：实例地址随实例变化，而这里的 BASE_URL 是编译期常量，
   * 直连就意味着每次开 GPU 都要改源码重新 Build。
   */
  async restorePhoto(token: string, imageBase64: string, model: string,
    scale: number, denoise: number, face: boolean): Promise<RestoreResult> {
    const httpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json' };
      if (token !== '') {
        header['Authorization'] = 'Bearer ' + token;
      }
      const response = await httpRequest.request(BASE_URL + '/app/restore-photo', {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify({
          image: imageBase64, model: model, scale: scale,
          denoise: denoise, face: face, colorize: true
        }),
        connectTimeout: 30000,
        readTimeout: 240000
      });
      const resultStr: string = typeof response.result === 'string'
        ? response.result
        : buffer.from(response.result as ArrayBuffer).toString('utf-8');
      const json: Record<string, Object> = resultStr === ''
        ? {} : JSON.parse(resultStr) as Record<string, Object>;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const errMsg: string = json['error']
          ? String(json['error']) : '修复失败(' + response.responseCode + ')';
        throw new Error(errMsg);
      }
      const image: string = json['image'] === undefined ? '' : String(json['image']);
      if (image === '') {
        throw new Error('修复服务返回缺少 image 字段');
      }
      const meta: Object | undefined = json['meta'];
      return { image: image, meta: meta };
    } finally {
      httpRequest.destroy();
    }
  }

  async register(data: RegisterData): Promise<UserInfo> {
    const obj: Record<string, Object> = await this.request(http.RequestMethod.POST, '/app/register', data, '');
    const user: UserInfo = {
      id: Number(obj['id']),
      username: String(obj['username']),
      role: String(obj['role']),
      name: String(obj['name']),
      student_no: String(obj['student_no']),
      school: String(obj['school']),
      class_name: String(obj['class_name']),
      grade_level: readNullableText(obj['grade_level'])
    };
    return user;
  }

  async login(data: LoginData): Promise<LoginResult> {
    const obj: Record<string, Object> = await this.request(http.RequestMethod.POST, '/app/login', data, '');
    const userObj: Record<string, Object> = obj['user'] as Record<string, Object>;
    const user: UserInfo = {
      id: Number(userObj['id']),
      username: String(userObj['username']),
      role: String(userObj['role']),
      name: String(userObj['name']),
      student_no: String(userObj['student_no']),
      school: String(userObj['school']),
      class_name: String(userObj['class_name']),
      grade_level: readNullableText(userObj['grade_level'])
    };
    const loginResult: LoginResult = {
      token: String(obj['token']),
      user: user
    };
    return loginResult;
  }

  async uploadProgress(token: string, pointId: string, pointName: string): Promise<void> {
    const body: Record<string, string> = { point_id: pointId, point_name: pointName };
    await this.request(http.RequestMethod.POST, '/app/progress', body, token);
  }

  async uploadReport(token: string, content: string, duration: number): Promise<void> {
    const body: Record<string, Object> = { content: content, duration: duration };
    await this.request(http.RequestMethod.POST, '/app/reports', body, token);
  }

  async uploadPhoto(token: string, beforeBase64: string, afterBase64: string): Promise<void> {
    const body: Record<string, string> = { before_image: beforeBase64, after_image: afterBase64 };
    await this.request(http.RequestMethod.POST, '/app/photos', body, token);
  }

  /** 上报一次打卡。source 是 camera（系统相机扫的）或 photo（相册扫的） */
  async uploadCheckin(token: string, spotKey: string, spotName: string, source: string): Promise<void> {
    const body: Record<string, string> = {
      spot_key: spotKey, spot_name: spotName, source: source
    };
    await this.request(http.RequestMethod.POST, '/app/checkins', body, token);
  }

  /** 上报当前路线。后端按 user_id 覆盖，每个学生只留一份 */
  async uploadRoute(token: string, grade: string, hours: string, stopsJson: string): Promise<void> {
    const body: Record<string, string> = { grade: grade, hours: hours, stops: stopsJson };
    await this.request(http.RequestMethod.POST, '/app/routes', body, token);
  }

  /** 上报一次测试成绩。detail 是逐题作答与对错的 JSON 字符串 */
  async uploadQuiz(token: string, grade: string, score: number, total: number, detailJson: string): Promise<void> {
    const body: Record<string, Object> = {
      grade: grade, score: score, total: total, detail: detailJson
    };
    await this.request(http.RequestMethod.POST, '/app/quiz', body, token);
  }

  /** 拉本班测试排名。本项目第一个「读」接口，request() 本来就通用，直接复用 */
  async fetchQuizRanking(token: string): Promise<Record<string, Object>> {
    return await this.request(http.RequestMethod.GET, '/app/quiz/ranking', null, token);
  }

  /**
   * 上报一次「本地知识库命中」。教师端的热门知识点以 App 的知识库为准，
   * 所以这里送的是 App 的条目编号（D0/F0 这种）与条目问句。
   */
  async uploadKnowledgeHit(token: string, knowledgeId: string, knowledgeQuestion: string): Promise<void> {
    const body: Record<string, string> = {
      knowledge_id: knowledgeId, knowledge_question: knowledgeQuestion
    };
    await this.request(http.RequestMethod.POST, '/app/knowledge-hits', body, token);
  }

  /**
   * 把 App 的整份知识库同步给教师端（后端整份替换）。
   * 送 JSON 字符串而不是数组 —— 与 stops / detail 的写法一致，避开 ArkTS 对
   * Record<string, Object> 里塞数组的类型限制。
   */
  async uploadKnowledgeSync(token: string, itemsJson: string): Promise<void> {
    const body: Record<string, string> = { items_json: itemsJson };
    await this.request(http.RequestMethod.POST, '/app/knowledge-sync', body, token);
  }
}
