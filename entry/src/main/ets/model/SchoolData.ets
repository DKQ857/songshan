/**
 * 注册页的学校 / 班级候选数据（云南保山龙陵地区，贴合松山研学）。
 *
 * 分组只有三档：小学 / 中学 / 大学 —— 与注册页的四个学段不是一一对应，
 * 初中和高中共用「中学」组（学校与班级都是）。要拆开就改 schoolsOf/classesOf。
 */

export const PRIMARY_SCHOOLS: string[] = [
  '保山市实验小学',
  '龙陵县中心小学',
  '保山市隆阳区第一小学',
  '腾冲市腾越镇中心小学',
  '施甸县甸阳镇小学',
  '昌宁县第一小学',
  '龙陵县腊勐镇中心小学',
  '保山市第二小学'
];

export const MIDDLE_SCHOOLS: string[] = [
  '保山市第一中学',
  '龙陵县第一中学',
  '保山市隆阳区第一中学',
  '腾冲市第一中学',
  '施甸县第一中学',
  '昌宁县第一中学',
  '龙陵县腊勐中学',
  '保山市实验中学'
];

export const UNIVERSITY_SCHOOLS: string[] = [
  '保山学院',
  '滇西科技师范学院',
  '云南大学',
  '昆明理工大学',
  '云南师范大学',
  '云南民族大学',
  '西南林业大学'
];

/**
 * 班级按「前缀 × 班号」生成。小学/中学写成「一年级(1)班」，
 * 大学写成「2023级1班」—— 不带括号，所以 withParen 要分开。
 */
function buildClasses(prefixes: string[], perGrade: number, withParen: boolean): string[] {
  const out: string[] = [];
  for (let i = 0; i < prefixes.length; i++) {
    for (let c = 1; c <= perGrade; c++) {
      out.push(withParen ? prefixes[i] + '(' + c + ')班' : prefixes[i] + c + '班');
    }
  }
  return out;
}

/** 一年级(1)班 ~ 六年级(3)班，共 18 个 */
export const PRIMARY_CLASSES: string[] = buildClasses(
  ['一年级', '二年级', '三年级', '四年级', '五年级', '六年级'], 3, true);

/** 初一(1)班 ~ 高三(3)班，共 18 个 */
export const MIDDLE_CLASSES: string[] = buildClasses(
  ['初一', '初二', '初三', '高一', '高二', '高三'], 3, true);

/** 2023级1班 ~ 2025级4班，共 12 个 */
export const UNIVERSITY_CLASSES: string[] = buildClasses(
  ['2023级', '2024级', '2025级'], 4, false);

export function schoolsOf(gradeLevel: string): string[] {
  if (gradeLevel === '小学') return PRIMARY_SCHOOLS;
  if (gradeLevel === '大学') return UNIVERSITY_SCHOOLS;
  return MIDDLE_SCHOOLS;
}

export function classesOf(gradeLevel: string): string[] {
  if (gradeLevel === '小学') return PRIMARY_CLASSES;
  if (gradeLevel === '大学') return UNIVERSITY_CLASSES;
  return MIDDLE_CLASSES;
}

/** 学号占位符按学段给例子 —— 只是提示，不做长度校验 */
export function studentNoPlaceholderOf(gradeLevel: string): string {
  if (gradeLevel === '小学') return '学号（如 20260101）';
  if (gradeLevel === '大学') return '学号（如 20230101）';
  return '学号（如 2026010101）';
}
