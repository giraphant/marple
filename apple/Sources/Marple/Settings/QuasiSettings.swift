import SwiftUI

struct QuasiSettings: View {
    @AppStorage(SettingsKeys.quasiExecutablePath) private var savedPath = ""
    @State private var path = ""
    @State private var configuration: QuasiConfiguration?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var revision = UUID()

    private var groups: [String] {
        var result: [String] = []
        for key in configuration?.keys ?? [] where !result.contains(key.group) {
            result.append(key.group)
        }
        return result
    }

    var body: some View {
        Form {
            Section("Quasi 入口") {
                TextField("scripts/quasi 的绝对路径", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadPath() }
                Button("保存路径并重新加载") { loadPath() }
                if busy {
                    ProgressView().controlSize(.small)
                }
                if let message {
                    Text(message)
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            ForEach(groups, id: \.self) { group in
                Section {
                    ForEach((configuration?.keys ?? []).filter { $0.group == group }) { key in
                        QuasiConfigRow(key: key) { value in
                            change(key.name, value: value)
                        }
                    }
                } header: { Text(group) }
            }
            .id(revision)
        }
        .formStyle(.grouped)
        .disabled(busy)
        .onAppear {
            guard !busy else { return }
            path = savedPath.isEmpty ? (QuasiConfigClient.discoverPath() ?? "") : savedPath
            loadPath()
        }
    }

    private func loadPath() {
        savedPath = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        path = savedPath
        message = nil
        failed = false
        configuration = nil
        busy = true
        let client = QuasiConfigClient(executablePath: savedPath)
        Task {
            await reload(client)
            busy = false
        }
    }

    private func change(_ name: String, value: String?) {
        busy = true
        message = nil
        let client = QuasiConfigClient(executablePath: savedPath)
        Task {
            do {
                if let value { try await client.set(name, value: value) }
                else { try await client.unset(name) }
                message = value == nil ? String(localized: "配置已清除。") : String(localized: "配置已保存。")
                failed = false
            } catch {
                message = error.localizedDescription
                failed = true
            }
            await reload(client)
            busy = false
        }
    }

    private func reload(_ client: QuasiConfigClient) async {
        do {
            configuration = try await client.show()
        } catch {
            configuration = nil
            message = [message, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            failed = true
        }
        revision = UUID() // Discard edited values, especially secrets, after each command.
    }
}

private struct QuasiConfigRow: View {
    let key: QuasiConfiguration.Key
    let save: (String?) -> Void
    @State private var value: String

    init(key: QuasiConfiguration.Key, save: @escaping (String?) -> Void) {
        self.key = key
        self.save = save
        _value = State(initialValue: key.displayedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.description)
                Spacer()
                Text(key.set ? String(localized: "已设") : String(localized: "未设"))
                    .foregroundStyle(.secondary)
                if key.set {
                    Button("清除", role: .destructive) { save(nil) }
                }
            }
            HStack {
                if key.secret {
                    SecureField("输入新值", text: $value)
                } else if let choices = key.choices, !choices.isEmpty {
                    Picker("配置值", selection: $value) {
                        if !choices.contains(value) { Text(value.isEmpty ? String(localized: "未设") : value).tag(value) }
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                } else {
                    TextField("配置值", text: $value)
                }
                Button("保存") { save(value) }
                    .disabled(value.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if !key.set, let defaultValue = key.default, !key.secret {
                Text("默认值：\(defaultValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if key.source == "env" {
                Text("当前由环境变量 \(key.env) 覆盖，这里改了暂时不生效")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
