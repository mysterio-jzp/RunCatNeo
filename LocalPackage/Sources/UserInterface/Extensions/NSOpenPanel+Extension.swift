/*
 NSOpenPanel+Extension.swift
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
import Foundation

extension NSOpenPanel {
    static func selectFolders(
        message: String,
        confirmationLabel: String
    ) async -> Result<[URL], any Error> {
        await withCheckedContinuation { continuation in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            panel.message = message
            panel.prompt = confirmationLabel
            panel.level = .modalPanel
            panel.center()
            let response = panel.runModal()
            precondition(Thread.isMainThread)
            if response == .OK, let url = panel.url {
                continuation.resume(returning: .success([url]))
            } else {
                continuation.resume(returning: .failure(CancellationError()))
            }
        }
    }
}