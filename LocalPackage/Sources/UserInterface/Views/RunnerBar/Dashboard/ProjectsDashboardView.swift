/*
 ProjectsDashboardView.swift
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
import Model
import SwiftUI

struct ProjectsDashboardView: View {
    @State var store: ProjectsDashboard
    @Environment(\.appDependencies) private var appDependencies

    private func currentIcon(for project: Project) -> NSImage? {
        guard let bundleIdentifier = project.applicationBundleIdentifier,
              let appURL = appDependencies.nsWorkspaceClient.urlForApplication(bundleIdentifier)
        else { return nil }
        return appDependencies.nsWorkspaceClient.applicationIcon(appURL)
    }

    private func openWithOptions(for project: Project) -> [OpenWithOption] {
        let workspace = appDependencies.nsWorkspaceClient
        var options: [OpenWithOption] = []
        var seen = Set<String>()
        for appURL in workspace.urlsForApplicationsOpening(project.folderURL) {
            guard let bundle = Bundle(url: appURL) else { continue }
            let bundleIdentifier = bundle.bundleIdentifier ?? appURL.path
            guard seen.insert(bundleIdentifier).inserted else { continue }
            options.append(OpenWithOption(
                bundleIdentifier: bundle.bundleIdentifier,
                name: displayName(of: appURL, bundle: bundle),
                icon: workspace.applicationIcon(appURL)
            ))
        }
        if let bundleIdentifier = project.applicationBundleIdentifier,
           !seen.contains(bundleIdentifier),
           let appURL = workspace.urlForApplication(bundleIdentifier),
           let bundle = Bundle(url: appURL) {
            options.append(OpenWithOption(
                bundleIdentifier: bundle.bundleIdentifier,
                name: displayName(of: appURL, bundle: bundle),
                icon: workspace.applicationIcon(appURL)
            ))
        }
        return options.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func displayName(of appURL: URL, bundle: Bundle) -> String {
        bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(spacing: 8) {
            if store.projects.isEmpty {
                Text("noProjects", bundle: .module)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .materialCellStyle()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.projects) { project in
                                ProjectRowView(
                                    project: project,
                                    currentIcon: currentIcon(for: project),
                                    openWithOptions: openWithOptions(for: project),
                                    openProject: {
                                        await store.send(.openProjectButtonTapped(project))
                                    },
                                    openWithPicked: { bundleIdentifier in
                                        await store.send(.openWithAppPicked(project, bundleIdentifier))
                                    },
                                    removeButtonTapped: {
                                        await store.send(.removeProjectButtonTapped(project.id))
                                    }
                                )
                            }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    Task {
                        let result = await NSOpenPanel.selectFolders(
                            message: String(localized: "chooseProjectFolder", bundle: .module),
                            confirmationLabel: String(localized: "add", bundle: .module)
                        )
                        await store.send(.fileImporterResponse(result))
                    }
                } label: {
                    Label {
                        Text("addProject", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .confirmationDialog(
            Text("removeProject", bundle: .module),
            isPresented: $store.showingConfirmationDialog,
            actions: {
                Button(role: .destructive) {
                    Task {
                        await store.send(.removingProjectConfirmed)
                    }
                } label: {
                    Text("remove", bundle: .module)
                }
                Button(role: .cancel) {
                    Task {
                        await store.send(.removingProjectCancelled)
                    }
                } label: {
                    Text("cancel", bundle: .module)
                }
            },
            message: {
                Text("removeProjectMessage", bundle: .module)
            }
        )
        .task {
            await store.send(.viewAppeared)
        }
        .onDisappear {
            Task {
                await store.send(.viewDisappeared)
            }
        }
    }
}