/*
 ProjectRowView.swift
 UserInterface

 Created by Kyome22 on 2026/08/10.
 Copyright 2026 Kyome22 (Takuto Nakamura)

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  */

import AppKit
import DataSource
import SwiftUI

struct OpenWithOption: Identifiable {
    var bundleIdentifier: String?
    var name: String
    var icon: NSImage?

    var id: String { bundleIdentifier ?? "system-default" }
}

struct ProjectRowView: View {
    var project: Project
    var currentIcon: NSImage?
    var openWithOptions: [OpenWithOption]
    var openProject: () async -> Void
    var openWithPicked: (String?) async -> Void
    var removeButtonTapped: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await openProject()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: project.name)
                        Text(verbatim: project.folderURL.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                ForEach(openWithOptions) { option in
                    Button {
                        Task {
                            await openWithPicked(option.bundleIdentifier)
                        }
                    } label: {
                        Label {
                            Text(option.name)
                        } icon: {
                            if let image = option.icon {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app.dashed")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let image = currentIcon {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app.dashed")
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(Text("openWith", bundle: .module))
            Button(role: .destructive) {
                Task {
                    await removeButtonTapped()
                }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .tint(Color.red)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .materialCellStyle()
    }
}