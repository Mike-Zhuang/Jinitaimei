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
                    Text("支持本地通知和邮件推送；邮件推送由后端低频轮询服务处理。")
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
    @StateObject private var followStore = StarActivityFollowStore.shared
    @State private var emailRecipient = ""
    @State private var isSyncingMailPush = false
    @State private var mailPushStatus: String?
    @State private var showCredentialSheet = false

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
                        updatePreferencesAndSyncMailIfNeeded { $0.teachingNoticeEnabled = value }
                    }
                ))
            } header: {
                Text("教学管理信息系统通知公告")
            }

            Section {
                Toggle("低余额提醒", isOn: Binding(
                    get: { preferenceStore.preferences.campusCardLowBalanceEnabled },
                    set: { value in
                        updatePreferencesAndSyncMailIfNeeded { $0.campusCardLowBalanceEnabled = value }
                    }
                ))

                HStack {
                    Text("提醒阈值")
                    Spacer()
                    TextField(
                        "50",
                        value: Binding(
                            get: { preferenceStore.preferences.campusCardLowBalanceThreshold },
                            set: { value in
                                preferenceStore.update { preferences in
                                    preferences.campusCardLowBalanceThreshold = min(max(value, 0), 9999)
                                }
                            }
                        ),
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 90)
                    Text("元")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("校园卡")
            } footer: {
                Text("当余额从高于阈值切换为低于或等于阈值时提醒一次；若余额持续偏低，不会反复骚扰。邮件推送将复用同一阈值。")
            }

            Section {
                Toggle("新活动但未开始报名", isOn: Binding(
                    get: { preferenceStore.preferences.starNewActivityEnabled },
                    set: { value in
                        updatePreferencesAndSyncMailIfNeeded { $0.starNewActivityEnabled = value }
                    }
                ))

                Toggle("关注活动开始报名", isOn: Binding(
                    get: { preferenceStore.preferences.starRegistrationEnabled },
                    set: { value in
                        updatePreferencesAndSyncMailIfNeeded { $0.starRegistrationEnabled = value }
                    }
                ))
            } header: {
                Text("卓越星")
            } footer: {
                Text("新活动提醒只针对所选星星种类中“新出现且尚未开始报名”的活动；活动列表中点铃铛可以关注某个活动，关注后若它从非报名状态切换到报名进行中，会发送提醒。")
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

            Section {
                Toggle("启用邮件推送", isOn: Binding(
                    get: { preferenceStore.preferences.mailPushEnabled },
                    set: setMailPushEnabled
                ))

                Button {
                    Task { await syncMailPushPreferences() }
                } label: {
                    if isSyncingMailPush {
                        ProgressView()
                    } else {
                        Text("同步邮件推送设置")
                    }
                }
                .disabled(isSyncingMailPush || !canSyncMailPush)

                Button("保存离线推送凭据") {
                    showCredentialSheet = true
                }
                .disabled(!canSyncMailPush)

                if preferenceStore.preferences.mailPushEnabled {
                    Button("关闭并删除服务器订阅", role: .destructive) {
                        Task { await deleteMailPushSubscription() }
                    }
                    .disabled(isSyncingMailPush || emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let mailPushStatus {
                    Text(mailPushStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("邮件推送")
            } footer: {
                Text("离线邮件推送会把你输入的同济统一身份账号密码发送到后端加密保存，用于低频轮询教务通知和卓越星提醒。关闭后会请求服务器删除订阅与凭据。")
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            saveEmailRecipient()
            if preferenceStore.preferences.mailPushEnabled {
                Task { await syncMailPushPreferences() }
            }
        }
        .task {
            emailRecipient = preferenceStore.preferences.emailRecipient
            await notificationManager.refreshAuthorizationStatus()
            if notificationManager.authorizationStatus == .denied {
                preferenceStore.update { $0.localNotificationsEnabled = false }
                await disableMailPushBecauseNotificationsAreOff()
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            MailPushCredentialSheet(
                email: emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            ) { username, password in
                await saveMailPushCredentials(username: username, password: password)
            }
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
                if !granted {
                    await disableMailPushBecauseNotificationsAreOff()
                }
            }
        } else {
            preferenceStore.update { $0.localNotificationsEnabled = false }
            Task { await disableMailPushBecauseNotificationsAreOff() }
        }
    }

    private var canSyncMailPush: Bool {
        emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
    }

    private func setMailPushEnabled(_ value: Bool) {
        if value {
            preferenceStore.update { $0.mailPushEnabled = true }
            Task { await syncMailPushPreferences() }
        } else {
            Task { await deleteMailPushSubscription(reason: "邮件推送已关闭，服务器订阅与凭据已删除") }
        }
    }

    private func toggleModule(_ code: String) {
        updatePreferencesAndSyncMailIfNeeded { preferences in
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

    private func updatePreferencesAndSyncMailIfNeeded(_ transform: @escaping (inout NotificationPreferences) -> Void) {
        preferenceStore.update(transform)
        if preferenceStore.preferences.mailPushEnabled {
            Task { await syncMailPushPreferences() }
        }
    }

    private func syncMailPushPreferences() async {
        guard !isSyncingMailPush else { return }
        saveEmailRecipient()
        guard canSyncMailPush else {
            mailPushStatus = "请先填写有效的接收邮箱"
            return
        }

        isSyncingMailPush = true
        defer { isSyncingMailPush = false }
        do {
            try await PushSubscriptionAPI().saveSubscription(
                preferenceStore.preferences,
                followedActivityIds: followStore.followedActivityIds
            )
            mailPushStatus = "邮件推送设置已同步"
        } catch {
            mailPushStatus = error.localizedDescription
        }
    }

    private func saveMailPushCredentials(username: String, password: String) async {
        guard canSyncMailPush else {
            mailPushStatus = "请先填写有效的接收邮箱"
            return
        }

        isSyncingMailPush = true
        defer { isSyncingMailPush = false }
        preferenceStore.update { $0.mailPushEnabled = true }
        saveEmailRecipient()
        do {
            let api = PushSubscriptionAPI()
            try await api.saveSubscription(
                preferenceStore.preferences,
                followedActivityIds: followStore.followedActivityIds
            )
            try await api.saveCredentials(
                email: preferenceStore.preferences.emailRecipient,
                username: username,
                password: password
            )
            mailPushStatus = "离线邮件推送凭据已加密保存到服务器"
        } catch {
            mailPushStatus = error.localizedDescription
        }
    }

    private func deleteMailPushSubscription() async {
        await deleteMailPushSubscription(reason: "服务器订阅与凭据已删除")
    }

    private func disableMailPushBecauseNotificationsAreOff() async {
        guard preferenceStore.preferences.mailPushEnabled else { return }
        await deleteMailPushSubscription(reason: "已关闭通知，邮件推送订阅与凭据已同步删除")
    }

    private func deleteMailPushSubscription(reason: String) async {
        guard !isSyncingMailPush else { return }
        let email = emailRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            preferenceStore.update { $0.mailPushEnabled = false }
            mailPushStatus = reason
            return
        }

        isSyncingMailPush = true
        defer { isSyncingMailPush = false }
        do {
            try await PushSubscriptionAPI().deleteSubscription(email: email)
            preferenceStore.update { $0.mailPushEnabled = false }
            mailPushStatus = reason
        } catch {
            mailPushStatus = error.localizedDescription
        }
    }
}

private struct MailPushCredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    let email: String
    let onSave: (String, String) async -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(email)
                        .foregroundStyle(.secondary)
                    TextField("统一身份认证账号", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("统一身份认证密码", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("后端离线轮询凭据")
                } footer: {
                    Text("保存后，后端会加密保存这组凭据，仅用于邮件提醒的低频轮询。遇到验证码或二次验证时会停止自动处理并邮件提醒你重新确认。")
                }

                Section {
                    Button {
                        Task {
                            isSaving = true
                            await onSave(username, password)
                            isSaving = false
                            dismiss()
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("同意并保存到服务器")
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSaving)
                }
            }
            .navigationTitle("邮件推送凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("取消") {
                    dismiss()
                }
            }
        }
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
                            YikatongStore(modelContext: modelContext).clearLocalData()
                            ExamScheduleStore(modelContext: modelContext).clearLocalData()
                            GradeStore(modelContext: modelContext).clearLocalData()
                            LibrarySpaceStore(modelContext: modelContext).clearLocalData()
                            WaterControlStore(modelContext: modelContext).clearLocalData()
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
