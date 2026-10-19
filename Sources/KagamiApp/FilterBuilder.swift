import KagamiCore
import SwiftUI

/// ⌘F: build a display filter from rows instead of typing Wireshark syntax. The filter it writes is
/// shown as it changes, so the syntax is learnt along the way.
struct FilterBuilderView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("filterBuilderMatchAll") private var all = true
    @State private var rules: [FilterRule] = [FilterRule()]

    private var result: String { FilterRule.combine(rules, all: all) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Show packets where").font(.headline)
                Picker("", selection: $all) {
                    Text("all rules match").tag(true)
                    Text("any rule matches").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach($rules) { $rule in
                    RuleRow(rule: $rule, canRemove: rules.count > 1) { rules.removeAll { $0.id == rule.id } }
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { rules.append(FilterRule(field: .port, condition: .equals)) }
            } label: { Label("Add Rule", systemImage: "plus") }
            .buttonStyle(.borderless)
            .disabled(rules.count >= 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("Wireshark filter").font(.caption).foregroundStyle(.secondary)
                Text(result.isEmpty ? "Fill in a rule to see the filter." : result)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(result.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            }
            HStack {
                Text("Hides packets only; the capture is unchanged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(nil)
                Button("Apply") { store.applyAsFilter(result); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(result.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 620)
    }
}

private struct RuleRow: View {
    @Binding var rule: FilterRule
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.enabled).labelsHidden().help("Turn this rule off without deleting it")
            Picker("Field", selection: $rule.field) {
                ForEach(FilterRule.Field.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 190)
            .onChange(of: rule.field) { if !rule.field.conditions.contains(rule.condition) { rule.condition = rule.field.conditions[0] } }
            Picker("Condition", selection: $rule.condition) {
                ForEach(rule.field.conditions) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            TextField(rule.field.placeholder, text: $rule.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .overlay(alignment: .trailing) {
                    if !rule.value.isEmpty && rule.expression == nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.trailing, 6)
                            .help("Not a valid value for this field")
                    }
                }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .help("Remove this rule")
        }
        .opacity(rule.enabled ? 1 : 0.5)
    }
}
