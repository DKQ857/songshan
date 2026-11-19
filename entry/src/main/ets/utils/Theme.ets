/**
 * 「数字沙盘 · 战时指挥所」主题 —— 全局设计 Token
 * 松山战役智能讲解员统一配色与字号，供各页面引用。
 * 抗战红 = rust（纪念/主操作）· 铜像 = bronze（品牌/高光）· 科技绿 = phosphor（仅实时态）
 */
export class AppColor {
  // 底色（松林深色系）
  static readonly ink: string = '#151A16';
  static readonly pine: string = '#1E2A22';
  static readonly pine2: string = '#26342A';
  // 卡其（军装中性色）
  static readonly khaki: string = '#D8CFAF';
  static readonly khakiMid: string = '#9A9279';
  static readonly khakiDim: string = '#6E6854';
  // 强调色（各司其职）
  static readonly rust: string = '#C44933';
  static readonly bronze: string = '#B08A57';
  static readonly phosphor: string = '#4FD79B';
  // 档案纸（浅色表面）
  static readonly paper: string = '#ECE4CE';
  static readonly paperInk: string = '#2A2418';
}

export class AppFont {
  static readonly brand: number = 24;
  static readonly title: number = 21;
  static readonly body: number = 15;
  static readonly button: number = 14;
  static readonly caption: number = 12;
}
