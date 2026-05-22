import SwiftUI
import SwiftData
import UserNotifications
import TongjiKit

/// 设置页：账户入口参考 DanXi-swift `FudanUI/General/AccountButton.swift`。
public struct SettingsPage: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @State private var showLogin = false
    @State private var showAccountSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    CampusAccountButton(
                        showLogin: $showLogin,
                        showAccountSheet: $showAccountSheet
                    )
                } header: {
                    Text("账户")
                }

                Section {
                    NavigationLink {
                        AutoLoginSettingsView()
                    } label: {
                        Label("自动登录", systemImage: "faceid")
                    }
                } header: {
                    Text("登录保持")
                } footer: {
                    Text("登录态过期时，先尝试静默续期；失败后若你开启了自动登录，会用 Face ID / Touch ID 解锁后回填账号密码。")
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("通知", systemImage: "bell.badge")
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("当前支持本地通知；邮件通知和远程推送会在后端服务准备好后接入。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .fullScreenCover(isPresented: $showLogin) {
                LoginPage {
                    showLogin = false
                    campusModel.refresh()
                }
            }
            .sheet(isPresented: $showAccountSheet) {
                AccountSheet()
            }
        }
    }
}

private struct NotificationSettingsView: View {
    @StateObject private var preferenceStore = NotificationPreferenceStore.shared
    @StateObject private var notificationManager = LocalNotificationManager.shared
    @State private var emailRecipient = ""

    private let modules = [
        ("hongwen", "弘文之星"),
        ("mingde", "明德之星"),
        ("shizhi", "矢志之星"),
        ("qiusuo", "求索之星"),
        ("lixing", "力行之星")
    ]

    var body: some View {
        Form {
            Section {
                Toggle("启用本地通知", isOn: Binding(
                    get: { preferenceStore.preferences.localNotificationsEnabled },
                    set: setLocalNotificationsEnabled
                ))

                LabeledContent("系统权限", value: authorizationText)

                if notificationManager.authorizationStatus == .denied {
                    Button("前往系统通知设置") {
                        notificationManager.openSystemSettings()
                    }
                }
            } header: {
                Text("通知权限")
            } footer: {
                Text("本地通知只会在 App 有机会刷新数据时检测新内容；长期后台实时提醒需要后续 APNs 或邮件服务端。")
            }

            Section {
                Toggle("新教务通知", isOn: Binding(
                    get: { preferenceStore.preferences.teachingNoticeEnabled },
                    set: { value in
                        preferenceStore.update { $0.teachingNoticeEnabled = value }
                    }
                ))
            } header: {
                Text("教学管理信息系统通知公告")
            }

            Section {
                Toggle("新活动但未开始报名", isOn: Binding(
                    get: { preferenceStore.preferences.starNewActivityEnabled },
                    set: { value in
                        preferenceStore.update { $0.starNewActivityEnabled = value }
                    }
                ))

                Toggle("关注活动开始报名", isOn: Binding(
                    get: { preferenceStore.preferences.starRegistrationEnabled },
                    set: { value in
                        preferenceStore.update { $0.starRegistrationEnabled = value }
                    }
                ))
            } header: {
                Text("卓越星")
            } footer: {
                Text("活动列表中点铃铛可以关注活动；关注后若它进入报名进行中，会发送提醒。")
            }

            Section("星星种类") {
                ForEach(modules, id: \.0) { code, title in
                    Button {
                        toggleModule(code)
                    } label: {
                        HStack {
                            Text(title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if preferenceStore.preferences.selectedStarModuleCodes.contains(code) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section {
                TextField("name@example.com", text: $emailRecipient)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .onSubmit(saveEmailRecipient)
                    .onChange(of: emailRecipient) { _, _ in
                        saveEmailRecipient()
                    }
            } header: {
                Text("邮件通知接收地址")
            } footer: {
                Text("邮件通知需要后端轮询服务部署后才会生效；发送邮箱密码只保存在服务器环境变量，不写入 App 或仓库。")
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            emailRecipient = preferenceStore.preferences.emailRecipient
            await notificationManager.refreshAuthorizationStatus()
        }
    }

    private var authorizationText: String {
        switch notificationManager.authorizationStatus {
        case .notDetermined: return "未询问"
        case .denied: return "已关闭"
        case .authorized: return "已开启"
        case .provisional: return "临时允许"
        case .ephemeral: return "临时会话"
        @unknown default: return "未知"
        }
    }

    private func setLocalNotificationsEnabled(_ value: Bool) {
        if value {
            Task {
                let granted = await notificationManager.requestAuthorization()
                preferenceStore.update { $0.localNotificationsEnabled = granted }
            }
        } else {
            preferenceStore.update { $0.localNotificationsEnabled = false }
        }
    }

    private func toggleModule(_ code: String) {
        preferenceStore.update { preferences in
            if preferences.selectedStarModuleCodes.contains(code) {
                preferences.selectedStarModuleCodes.remove(code)
            } else {
                preferences.selectedStarModuleCodes.insert(code)
            }
        }
    }

    private func saveEmailRecipient() {
        preferenceStore.update { $0.emailRecipient = emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private struct CampusAccountButton: View {
    @ObservedObject private var campusModel = CampusModel.shared
    @Binding var showLogin: Bool
    @Binding var showAccountSheet: Bool

    var body: some View {
        Button {
            if campusModel.loggedIn {
                showAccountSheet = true
            } else {
                showLogin = true
            }
        } label: {
            HStack {
                Image(systemName: campusModel.loggedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.fill")
                    .font(.system(size: 42))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        campusModel.loggedIn ? Color.accentColor : Color.secondary,
                        campusModel.loggedIn ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.3)
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("同济校园账户")
                        .foregroundStyle(.primary)
                        .fontWeight(.semibold)
                    Text(campusModel.loggedIn ? "已登录" : "未登录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var campusModel = CampusModel.shared

    var body: some View {
        NavigationStack {
            Form {
                List {
                    if let profile = campusModel.profile {
                        Section {
                            LabeledContent("姓名", value: profile.name)
                            LabeledContent("学号", value: profile.uid)
                            if let facultyName = profile.facultyName {
                                LabeledContent("学院 / 书院", value: facultyName)
                            }
                            if let deptOrMajor = profile.deptOrMajor,
                               deptOrMajor != profile.facultyName {
                                LabeledContent("专业 / 部门", value: deptOrMajor)
                            }
                            if let grade = profile.grade {
                                LabeledContent("年级", value: grade)
                            }
                            if let loginTime = profile.loginTime {
                                LabeledContent("登录时间", value: loginTime)
                            }
                            if let lastLoginTime = profile.lastLoginTime {
                                LabeledContent("上次登录", value: lastLoginTime)
                            }
                        }
                    } else {
                        Section {
                            ContentUnavailableView(
                                "暂无账户信息",
                                systemImage: "person.crop.circle.badge.questionmark",
                                description: Text("请重新登录校园账户后查看。")
                            )
                            .listEmptyRowStyle()
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            CourseStore(modelContext: modelContext).clearLocalData()
                            ActivityStore(modelContext: modelContext).clearLocalData()
                            campusModel.logout()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("退出登录")
                                Spacer()
                            }
                        }
                    }
                }
                .navigationTitle("账户信息")
                .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .task {
                await campusModel.refreshProfile()
            }
        }
    }
}
