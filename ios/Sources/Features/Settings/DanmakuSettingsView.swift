//
//  DanmakuSettingsView.swift
//  弹幕设置（P6+，照着用户给的同类 App 那张设置页做的）
//
//  包含：启用弹幕 / 弹幕服务来源（本地服务·源自带 · 自定义远程）/ 顶部弹幕 / 底部弹幕 /
//        弹幕颜色（自带色）/ 屏蔽词 / 字号 / 行间距 / 透明度。
//

import SwiftUI

struct DanmakuSettingsView: View {

    @ObservedObject private var library = LibraryStore.shared

    @State private var blockWords = ""
    @State private var newWord = ""

    var body: some View {
        List {
            Section("开关") {
                Toggle("启用弹幕", isOn: binding(\.danmakuEnabled))
                Toggle("显示顶部弹幕", isOn: binding(\.danmakuShowTop))
                Toggle("显示底部弹幕", isOn: binding(\.danmakuShowBottom))
            }

            Section("弹幕服务来源") {
                Picker("来源", selection: binding(\.danmakuSource)) {
                    Text("源自带").tag("local")
                    Text("自定义远程").tag("remote")
                }
                .pickerStyle(.segmented)

                if library.settings.danmakuSource == "remote" {
                    TextField("http://ip:9321/TOKEN 或 http://ip:9321", text: binding(\.danmakuRemoteURL))
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("填别的设备/容器上跑的弹幕服务（兼容弹弹play 那几个接口）。留空就用源自带的。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("用源自己的弹幕服务（订阅里带的那个；A 家族是 /danmu/auto，B 家族是它内置的弹幕 API）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("样式") {
                slider("字号", value: binding(\.danmakuFontSize), range: 10...30, suffix: "pt")
                slider("行间距", value: binding(\.danmakuLaneSpacing), range: 1.0...2.5, suffix: "")
                slider("透明度", value: binding(\.danmakuOpacity), range: 0.2...1.0, suffix: "")
                HStack {
                    Text("弹幕颜色")
                    Spacer()
                    Text("自带色")
                        .foregroundStyle(.secondary)
                }
            }

            Section("屏蔽词（\(blockWords.count) 个）") {
                HStack {
                    TextField("加一个词，回车", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("加上") { addWord() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if blockWords.isEmpty {
                    Text("带这些词的弹幕不会显示（例如：打广告、剧透）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blockWords.split(separator: ",").map(String.init), id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                removeWord(word)
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("弹幕")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { blockWords = library.settings.danmakuBlockWords }
    }

    // MARK: - 小工具

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { library.settings[keyPath: keyPath] },
                set: { library.settings[keyPath: keyPath] = $0 })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: range.upperBound > 3 ? "%.0f%@" : "%.2f%@", value.wrappedValue, suffix))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        var words = blockWords.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !words.contains(word) else { newWord = ""; return }
        words.append(word)
        blockWords = words.joined(separator: ",")
        library.settings.danmakuBlockWords = blockWords
        newWord = ""
    }

    private func removeWord(_ word: String) {
        let words = blockWords.split(separator: ",").map(String.init).filter { $0 != word }
        blockWords = words.joined(separator: ",")
        library.settings.danmakuBlockWords = blockWords
    }
}
