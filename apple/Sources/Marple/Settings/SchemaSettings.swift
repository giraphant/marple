import SwiftUI
import AppKit
import MarpleKit

/// QUA-222: graphical editor for the L0 declaration table
/// (`vault/schema/schema.yaml`). Edits a local copy of `VaultSchema.active`;
/// 保存 writes the minimal override (diff vs builtin) and reloads the index so
/// sidebar/list icons repaint. Reaches the live model via `ActiveModel.current`,
/// same as the other model-backed panes.
///
/// Three sections mirror the override format: 显示 (type → SF Symbol + tint),
/// 实体别名 (entity → ordered fields), 路径引用 (rule③ onType/field/kind rows).
/// Whatever isn't touched stays builtin and keeps tracking future defaults.
struct SchemaSettings: View {
    @State private var schema: VaultSchema = .builtin
    @State private var original: VaultSchema = .builtin
    @State private var seeded = false
    @State private var newEntityName = ""
    @State private var saveError: String?
    /// Per-type required-field schema (`.quasi/schema.json`), shown read-only —
    /// it is owned and written by the Quasi pipeline; Marple is a pure consumer.
    @State private var snapshot: SchemaSnapshot?

    /// 内置默认色板 — also the tint Picker's options. Kept local to the editor
    /// (TypeIcon's `EntryType.tint` reads the *global* active schema, so it can't
    /// preview unsaved edits).
    private static let tints: [(name: String, color: Color)] = [
        ("blue", .blue), ("orange", .orange), ("purple", .purple), ("teal", .teal),
        ("green", .green), ("indigo", .indigo), ("yellow", .yellow), ("pink", .pink),
        ("red", .red), ("brown", .brown), ("mint", .mint), ("cyan", .cyan), ("gray", .gray),
    ]

    /// Stable display order: the modeled sidebar order, then transcript, then any
    /// extra keys a user added.
    private var displayKeys: [String] {
        var keys = EntryType.modeled.map(\.rawValue) + ["transcript"]
        for k in schema.displayByType.keys.sorted() where !keys.contains(k) { keys.append(k) }
        return keys
    }

    /// Builtin entities first (author/journal/topic), then user-added, sorted.
    private var entityKeys: [String] {
        let builtin = ["author", "journal", "topic"]
        let extra = schema.entityAliases.keys.filter { !builtin.contains($0) }.sorted()
        return builtin.filter { schema.entityAliases[$0] != nil } + extra
    }

    private var isDirty: Bool { schema != original }

    var body: some View {
        if ActiveModel.current?.workspaceRoot.isEmpty ?? true {
            Form {
                Section { Text("尚未打开文库。").foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
        } else {
            Form {
                displaySection
                typeFieldsSection
                aliasSection
                pathRefSection
                footer
            }
            .formStyle(.grouped)
            .onAppear {
                guard !seeded else { return }
                schema = .active
                original = .active
                snapshot = SchemaSnapshot.load(workspaceRoot: ActiveModel.current?.workspaceRoot ?? "")
                seeded = true
            }
        }
    }

    // MARK: 显示

    private var displaySection: some View {
        Section("显示") {
            ForEach(displayKeys, id: \.self) { key in
                let d = schema.displayByType[key] ?? schema.fallbackDisplay
                HStack(spacing: Space.s4) {
                    SchemaBadge(symbol: d.symbol, tint: Self.color(d.tint))
                    Text(EntryType(rawValue: key).label)
                        .frame(width: 52, alignment: .leading)
                    TextField("SF Symbol", text: symbolBinding(key), prompt: Text("SF Symbol"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    tintPicker(key).labelsHidden().frame(width: 96)
                }
            }
            Text("图标用 SF Symbol 名（如 doc.text）；色名取自固定调色板。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 类型字段（只读 · 由 Quasi 维护）

    private var typeFieldsSection: some View {
        Section("类型字段（只读）") {
            if let snapshot, !snapshot.requiredByType.isEmpty {
                ForEach(typeFieldKeys(snapshot), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        Text(EntryType(rawValue: key).label)
                            .frame(width: 52, alignment: .leading)
                        Text(snapshot.requiredByType[key]?.joined(separator: "、") ?? "—")
                            .font(Typo.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("每种类型的必填字段，由 Quasi 流水线写入 .quasi/schema.json，此处只读。缺字段会在列表 / 检查器里标红。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("尚无类型字段快照。运行 Quasi audit 生成 .quasi/schema.json 后，这里会列出每种类型的必填字段。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Modeled order first, then any extra snapshot-only types, dropping types the
    /// snapshot has no opinion on.
    private func typeFieldKeys(_ s: SchemaSnapshot) -> [String] {
        var keys = EntryType.modeled.map(\.rawValue) + ["transcript"]
        for k in s.requiredByType.keys.sorted() where !keys.contains(k) { keys.append(k) }
        return keys.filter { s.requiredByType[$0] != nil }
    }

    // MARK: 实体别名

    private var aliasSection: some View {
        Section("实体别名") {
            ForEach(entityKeys, id: \.self) { entity in
                entityEditor(entity)
            }
            HStack {
                TextField("新实体名", text: $newEntityName, prompt: Text("新实体名（如 translator）"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                Button("添加实体") { addEntity() }
                    .disabled(!canAddEntity)
            }
            Text("字段值是实体名（经 NameResolver 解析到同名类型的页面）。按声明顺序匹配，先声明的字段赢。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func entityEditor(_ entity: String) -> some View {
        let aliases = schema.entityAliases[entity] ?? []
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(entity).font(Typo.headline)
                Spacer()
                Button(role: .destructive) { removeEntity(entity) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除整个实体")
            }
            ForEach(Array(aliases.enumerated()), id: \.offset) { idx, alias in
                HStack(spacing: Space.s2) {
                    TextField("字段名", text: fieldBinding(entity, idx), prompt: Text("字段名"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Text("仅限").font(Typo.callout).foregroundStyle(.secondary)
                    TextField("仅限类型", text: onlyTypeBinding(entity, idx), prompt: Text("全部类型"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(width: 110)
                    Button { removeField(entity, idx) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(aliases.count <= 1) // 整实体不可空：删到最后一项请删实体
                }
            }
            Button("添加字段") { addField(entity) }
                .buttonStyle(.borderless).font(Typo.body)
        }
        .padding(.vertical, Space.s2)
    }

    // MARK: 路径引用

    private var pathRefSection: some View {
        Section("路径关联") {
            ForEach(Array(schema.pathReferences.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: Space.s2) {
                    TextField("源类型", text: pathRefBinding(idx, \.onType), prompt: Text("源类型"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    TextField("字段名", text: pathRefBinding(idx, \.field), prompt: Text("字段名"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    TextField("关联类型", text: pathRefBinding(idx, \.kind), prompt: Text("关联类型"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Button { removePathRef(idx) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("添加路径关联") { addPathRef() }
                .buttonStyle(.borderless).font(Typo.body)
            Text("某些字段的值是指向另一条目的路径（如笔记的 annotates 指向被批注的章节），据此建立关联。源类型 / 字段名 / 关联类型 三项都要填；全部删空则恢复内置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 底部操作

    private var footer: some View {
        Section {
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("全部恢复默认") { schema = .builtin }
                    .disabled(schema == .builtin)
                Spacer()
                Button("撤销改动") { schema = original }
                    .disabled(!isDirty)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            Text("保存写入 vault/schema/schema.yaml（只记录与默认不同的项）并即时刷新图标。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func symbolBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { schema.displayByType[key]?.symbol ?? schema.fallbackDisplay.symbol },
            set: { schema.displayByType[key] = .init(symbol: $0, tint: schema.displayByType[key]?.tint ?? schema.fallbackDisplay.tint) })
    }

    private func tintPicker(_ key: String) -> some View {
        Picker("", selection: Binding(
            get: { schema.displayByType[key]?.tint ?? schema.fallbackDisplay.tint },
            set: { schema.displayByType[key] = .init(symbol: schema.displayByType[key]?.symbol ?? schema.fallbackDisplay.symbol, tint: $0) }
        )) {
            ForEach(Self.tints, id: \.name) { t in
                Label(t.name, systemImage: "circle.fill").tint(t.color).tag(t.name)
            }
        }
    }

    private func fieldBinding(_ entity: String, _ idx: Int) -> Binding<String> {
        Binding(
            get: { schema.entityAliases[entity]?[safe: idx]?.field ?? "" },
            set: { newValue in
                guard var arr = schema.entityAliases[entity], arr.indices.contains(idx) else { return }
                arr[idx] = .init(newValue, onlyForType: arr[idx].onlyForType)
                schema.entityAliases[entity] = arr
            })
    }

    private func onlyTypeBinding(_ entity: String, _ idx: Int) -> Binding<String> {
        Binding(
            get: { schema.entityAliases[entity]?[safe: idx]?.onlyForType ?? "" },
            set: { newValue in
                guard var arr = schema.entityAliases[entity], arr.indices.contains(idx) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                arr[idx] = .init(arr[idx].field, onlyForType: trimmed.isEmpty ? nil : trimmed)
                schema.entityAliases[entity] = arr
            })
    }

    private func pathRefBinding(_ idx: Int, _ keyPath: KeyPath<VaultSchema.PathReference, String>) -> Binding<String> {
        Binding(
            get: { schema.pathReferences[safe: idx]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard schema.pathReferences.indices.contains(idx) else { return }
                let r = schema.pathReferences[idx]
                schema.pathReferences[idx] = .init(
                    onType: keyPath == \.onType ? newValue : r.onType,
                    field:  keyPath == \.field  ? newValue : r.field,
                    kind:   keyPath == \.kind   ? newValue : r.kind)
            })
    }

    // MARK: - Mutators

    private var canAddEntity: Bool {
        let name = newEntityName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && schema.entityAliases[name] == nil
    }

    private func addEntity() {
        let name = newEntityName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, schema.entityAliases[name] == nil else { return }
        schema.entityAliases[name] = [.init("")]
        newEntityName = ""
    }

    private func removeEntity(_ entity: String) { schema.entityAliases[entity] = nil }

    private func addField(_ entity: String) {
        schema.entityAliases[entity, default: []].append(.init(""))
    }

    private func removeField(_ entity: String, _ idx: Int) {
        guard var arr = schema.entityAliases[entity], arr.indices.contains(idx) else { return }
        arr.remove(at: idx)
        schema.entityAliases[entity] = arr
    }

    private func addPathRef() {
        schema.pathReferences.append(.init(onType: "", field: "", kind: ""))
    }

    private func removePathRef(_ idx: Int) {
        guard schema.pathReferences.indices.contains(idx) else { return }
        schema.pathReferences.remove(at: idx)
    }

    // MARK: - Save

    private func save() {
        guard let model = ActiveModel.current else { return }
        // 去掉空字段/空别名实体：覆盖格式无法表达空列表，留着只会在 reload 时悄悄回退。
        sanitize()
        do {
            try schema.save(workspaceRoot: model.workspaceRoot)
            VaultSchema.active = schema          // 即时反馈
            original = schema
            saveError = nil
            Task { await model.loadIndex() }      // 从磁盘重新合并 + 重绘图标
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    /// Drop empty field names and entities left with no fields, and path-reference
    /// rows missing any of onType/field/kind — none survive a load round-trip.
    private func sanitize() {
        for (entity, aliases) in schema.entityAliases {
            let kept = aliases.filter { !$0.field.trimmingCharacters(in: .whitespaces).isEmpty }
            if kept.isEmpty { schema.entityAliases[entity] = nil }
            else { schema.entityAliases[entity] = kept }
        }
        schema.pathReferences = schema.pathReferences.filter {
            !$0.onType.isEmpty && !$0.field.isEmpty && !$0.kind.isEmpty
        }
    }

    private static func color(_ tint: String) -> Color {
        tints.first { $0.name == tint }?.color ?? .gray
    }
}

/// Live preview swatch for the 显示 section — independent of the global active
/// schema so it reflects unsaved edits (mirrors `TypeBadge`'s look).
private struct SchemaBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.opacity(0.18))
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: symbol.isEmpty ? "questionmark" : symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint))
    }
}
