import SwiftUI
import SwiftData
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
