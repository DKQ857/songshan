import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { UserManager } from '../utils/UserManager';
import { BackendService, RegisterData } from '../utils/BackendService';
import { LocalAuth, LocalRegisterInput } from '../utils/LocalAuth';
import { schoolsOf, classesOf, studentNoPlaceholderOf } from '../model/SchoolData';

@Entry
@Component
struct RegisterPage {
  @State username: string = '';
  @State password: string = '';
  @State confirmPassword: string = '';
  @State role: string = 'student';
  /**
   * 学段：小学 / 初中 / 高中 / 大学。
   * 要存到后端（app_users.grade_level），出题时按它选卷子：
   * 小学→小学卷，初中和高中→中学卷，大学→大学卷。
   */
  @State gradeLevel: string = '小学';
  @State name: string = '';
  @State studentNo: string = '';
  @State school: string = '';
  @State className: string = '';
  /**
   * Select 的下标。与 school / className 是两套状态，必须同步维护 ——
   * 只要有一处没跟着改，就会提交出「学段=小学、学校=保山市第一中学」这种脏组合。
   */
  @State schoolIndex: number = -1;
  @State classIndex: number = -1;

  /**
   * 切学段。
   *
   * 学校与班级的候选集都随学段变，所以必须清空已选值 —— 旧选中项在新候选集里
   * 可能根本不存在（如「龙陵县中心小学」在中学组里没有），不清就会把学段与
   * 学校对不上的组合写进账号。
   */
  private selectGrade(level: string): void {
    if (this.gradeLevel === level) return;
    this.gradeLevel = level;
    this.school = '';
    this.schoolIndex = -1;
    this.className = '';
    this.classIndex = -1;
  }

  private schoolOptions(): SelectOption[] {
    const list: string[] = schoolsOf(this.gradeLevel);
    const opts: SelectOption[] = [];
    for (let i = 0; i < list.length; i++) {
      opts.push({ value: list[i] });
    }
    return opts;
  }

  private classOptions(): SelectOption[] {
    const list: string[] = classesOf(this.gradeLevel);
    const opts: SelectOption[] = [];
    for (let i = 0; i < list.length; i++) {
      opts.push({ value: list[i] });
    }
    return opts;
  }

  /**
   * 注册写本地账号体系（与登录同源），不以后端成功为前提。
   *
   * 以前这里等后端返回，后端一旦不可达就注册失败；更糟的是后端注册成功、
   * 登录却对不上（账号记在后端、App 无凭据）时，表现为「注册说成功，登录进不去」。
   * 现在本地是权威，后端只是旁路同步。
   */
  private async handleRegister(): Promise<void> {
    if (this.username.trim() === '') {
      promptAction.showToast({ message: '请输入用户名' });
      return;
    }
    if (this.password.length < 6) {
      promptAction.showToast({ message: '密码长度不能少于6位' });
      return;
    }
    if (this.confirmPassword !== this.password) {
      promptAction.showToast({ message: '两次输入的密码不一致' });
      return;
    }
    if (this.role === 'student') {
      if (this.studentNo.trim() === '' || this.name.trim() === '' || this.school.trim() === '' || this.className.trim() === '') {
        promptAction.showToast({ message: '请完整填写学号、姓名，并选择学校、班级' });
        return;
      }
    } else if (this.role === 'teacher') {
      if (this.name.trim() === '' || this.school.trim() === '' || this.className.trim() === '') {
        promptAction.showToast({ message: '请完整填写姓名、学校、所教班级' });
        return;
      }
    }

    const data: RegisterData = {
      username: this.username.trim(),
      password: this.password,
      role: this.role
    };
    if (this.role === 'student') {
      data.name = this.name.trim();
      data.student_no = this.studentNo.trim();
      data.school = this.school.trim();
      data.class_name = this.className.trim();
      data.grade_level = this.gradeLevel;
    } else if (this.role === 'teacher') {
      data.name = this.name.trim();
      data.school = this.school.trim();
      data.class_name = this.className.trim();
    }

    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const localAuth: LocalAuth = new LocalAuth(context);
    const userManager: UserManager = new UserManager(context);
    const input: LocalRegisterInput = {
      username: data.username,
      password: this.password,
      role: this.role,
      name: data.name,
      student_no: data.student_no,
      school: data.school,
      class_name: data.class_name,
      grade_level: data.grade_level
    };
    try {
      await localAuth.ensureSeeded();
      const err: string | null = await localAuth.register(input);
      if (err !== null) {
        promptAction.showToast({ message: err });
        return;
      }
    } catch (e) {
      console.error('[RegisterPage] 本地注册异常: ' + (e as Error).message);
      promptAction.showToast({ message: '注册失败，请重试' });
      return;
    }
    // 教师端可见性：后端可达时顺手同步一份，失败静默 —— 与 Index.ets 的上报同一规矩。
    // 录制演示视频时教师端仍能看到 App 注册的学生；评委离线时这一步无声跳过。
    this.syncToBackend(data);
    await userManager.saveRememberedUsername(this.username.trim());
    promptAction.showToast({ message: '注册成功' });
    router.back();
  }

  private syncToBackend(data: RegisterData): void {
    const backend: BackendService = new BackendService();
    backend.register(data).catch((e: Error) => {
      console.error('[RegisterPage] 后端同步失败（已忽略）: ' + e.message);
    });
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
          Text('注册账号').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFD700')
            .shadow({ radius: 8, color: 'rgba(255,215,0,0.5)' })
          Text('创建研学账号').fontSize(13).fontColor('#FFAAAA').margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 60, bottom: 20 })

        Scroll() {
          Column() {
            TextInput({ text: this.username, placeholder: '请输入用户名' })
              .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
              .onChange((value: string) => { this.username = value; })

            TextInput({ text: this.password, placeholder: '请输入密码（不少于6位）' })
              .type(InputType.Password)
              .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
              .margin({ top: 12 })
              .onChange((value: string) => { this.password = value; })

            TextInput({ text: this.confirmPassword, placeholder: '请再次输入密码' })
              .type(InputType.Password)
              .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
              .margin({ top: 12 })
              .onChange((value: string) => { this.confirmPassword = value; })

            Row() {
              Text('身份：').fontSize(15).fontColor('#2E0000')
              Button('学生').fontSize(14).height(32).padding({ left: 14, right: 14 })
                .backgroundColor(this.role === 'student' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(Color.White).borderRadius(16)
                .onClick(() => { this.role = 'student'; })
              Button('游客').fontSize(14).height(32).padding({ left: 14, right: 14 })
                .backgroundColor(this.role === 'tourist' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(Color.White).borderRadius(16).margin({ left: 10 })
                .onClick(() => { this.role = 'tourist'; })
              Button('教师').fontSize(14).height(32).padding({ left: 14, right: 14 })
                .backgroundColor(this.role === 'teacher' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                .fontColor(Color.White).borderRadius(16).margin({ left: 10 })
                .onClick(() => { this.role = 'teacher'; })
            }
            .width('100%')
            .margin({ top: 14 })
            .alignItems(VerticalAlign.Center)

            if (this.role === 'student') {
              // 学段决定出哪套卷子，所以注册时就要定下来
              Row() {
                Text('学段：').fontSize(15).fontColor('#2E0000')
                Button('小学').fontSize(14).height(32).padding({ left: 12, right: 12 })
                  .backgroundColor(this.gradeLevel === '小学' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                  .fontColor(Color.White).borderRadius(16)
                  .onClick(() => { this.selectGrade('小学'); })
                Button('初中').fontSize(14).height(32).padding({ left: 12, right: 12 })
                  .backgroundColor(this.gradeLevel === '初中' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                  .fontColor(Color.White).borderRadius(16).margin({ left: 8 })
                  .onClick(() => { this.selectGrade('初中'); })
                Button('高中').fontSize(14).height(32).padding({ left: 12, right: 12 })
                  .backgroundColor(this.gradeLevel === '高中' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                  .fontColor(Color.White).borderRadius(16).margin({ left: 8 })
                  .onClick(() => { this.selectGrade('高中'); })
                Button('大学').fontSize(14).height(32).padding({ left: 12, right: 12 })
                  .backgroundColor(this.gradeLevel === '大学' ? '#8B0000' : 'rgba(160,0,0,0.4)')
                  .fontColor(Color.White).borderRadius(16).margin({ left: 8 })
                  .onClick(() => { this.selectGrade('大学'); })
              }
              .width('100%').margin({ top: 12 })
              .alignItems(VerticalAlign.Center)

              TextInput({ text: this.studentNo, placeholder: studentNoPlaceholderOf(this.gradeLevel) })
                .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
                .margin({ top: 12 }).onChange((value: string) => { this.studentNo = value; })
              TextInput({ text: this.name, placeholder: '姓名（必填）' })
                .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
                .margin({ top: 12 }).onChange((value: string) => { this.name = value; })

              // 学校与班级按学段过滤，候选集在 model/SchoolData.ets。
              // 长校名（最长 10 字）在 44vp 行高里放得下，超长时由 Select 省略，
              // 不换行 —— 换行会撑破与其他输入框一致的行高。
              Select(this.schoolOptions())
                .selected(this.schoolIndex)
                .value(this.school === '' ? '请选择学校' : this.school)
                .width('100%').height(44)
                .font({ size: 15 }).fontColor('#2E0000')
                .backgroundColor(Color.White).borderRadius(10)
                .optionWidth(240)
                .margin({ top: 12 })
                .onSelect((index: number) => {
                  this.schoolIndex = index;
                  this.school = schoolsOf(this.gradeLevel)[index];
                })

              Select(this.classOptions())
                .selected(this.classIndex)
                .value(this.className === '' ? '请选择班级' : this.className)
                .width('100%').height(44)
                .font({ size: 15 }).fontColor('#2E0000')
                .backgroundColor(Color.White).borderRadius(10)
                .optionWidth(240)
                .margin({ top: 12 })
                .onSelect((index: number) => {
                  this.classIndex = index;
                  this.className = classesOf(this.gradeLevel)[index];
                })
            } else if (this.role === 'teacher') {
              TextInput({ text: this.name, placeholder: '姓名（必填）' })
                .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
                .margin({ top: 12 }).onChange((value: string) => { this.name = value; })
              TextInput({ text: this.school, placeholder: '学校（必填）' })
                .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
                .margin({ top: 12 }).onChange((value: string) => { this.school = value; })
              TextInput({ text: this.className, placeholder: '所教班级（必填）' })
                .height(44).fontSize(15).backgroundColor(Color.White).borderRadius(10)
                .margin({ top: 12 }).onChange((value: string) => { this.className = value; })
            }

            Button('注 册')
              .width('100%').height(46).fontSize(17).fontWeight(FontWeight.Bold)
              .backgroundColor('#8B0000').fontColor(Color.White).borderRadius(10)
              .margin({ top: 22 })
              .shadow({ radius: 8, color: 'rgba(139,0,0,0.5)' })
              .onClick(() => { this.handleRegister(); })

            Button('已有账号？返回登录')
              .width('100%').height(40).fontSize(14)
              .backgroundColor(Color.Transparent).fontColor('#FFD700').borderRadius(10)
              .margin({ top: 6 })
              .onClick(() => { router.back(); })
          }
          .width('100%')
        }
        .width('86%')
        .height('76%')
        .padding(20)
        .backgroundColor('rgba(255,248,220,0.92)')
        .borderRadius(20)
        .shadow({ radius: 20, color: 'rgba(0,0,0,0.3)' })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
