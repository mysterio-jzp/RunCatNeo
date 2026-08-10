/*
 ProjectsDashboard.swift
 Model

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

import DataSource
import Foundation
import Observation

@MainActor @Observable
public final class ProjectsDashboard: Composable {
    private let userDefaultsRepository: UserDefaultsRepository
    private let nsWorkspaceClient: NSWorkspaceClient
    private let urlClient: URLClient
    private let uuidClient: UUIDClient
    private let dateClient: DateClient
    private let logService: LogService

    public var projects: [Project]
    public var showingConfirmationDialog: Bool
    public var pendingRemovalProjectID: UUID?
    public let action: (Action) async -> Void

    public init(
        _ appDependencies: AppDependencies,
        projects: [Project]? = nil,
        showingConfirmationDialog: Bool = false,
        pendingRemovalProjectID: UUID? = nil,
        action: @escaping (Action) async -> Void = { _ in }
    ) {
        self.userDefaultsRepository = .init(appDependencies.userDefaultsClient)
        self.nsWorkspaceClient = appDependencies.nsWorkspaceClient
        self.urlClient = appDependencies.urlClient
        self.uuidClient = appDependencies.uuidClient
        self.dateClient = appDependencies.dateClient
        self.logService = .init(appDependencies)
        self.projects = projects ?? userDefaultsRepository.projectsConfiguration.projects
        self.showingConfirmationDialog = showingConfirmationDialog
        self.pendingRemovalProjectID = pendingRemovalProjectID
        self.action = action
    }

    public func reduce(_ action: Action) async {
        switch action {
        case .viewAppeared:
            projects = projectsInheritingDefaultApplication()

        case .viewDisappeared:
            return

        case let .fileImporterResponse(.success(urls)):
            guard let url = urls.first else { return }
            do {
                try addProject(of: url)
                projects = userDefaultsRepository.projectsConfiguration.projects
            } catch let error as RCNError {
                await send(.errorOccurred(error))
            } catch {
                logService.critical(.unknown(error))
            }

        case let .fileImporterResponse(.failure(error)):
            logService.error(.importingProjectFailed(error))

        case let .removeProjectButtonTapped(id):
            pendingRemovalProjectID = id
            showingConfirmationDialog = true

        case .removingProjectConfirmed:
            guard let projectID = pendingRemovalProjectID else { return }
            removeProject(of: projectID)
            projects = userDefaultsRepository.projectsConfiguration.projects
            pendingRemovalProjectID = nil

        case .removingProjectCancelled:
            pendingRemovalProjectID = nil

        case let .openProjectButtonTapped(project):
            do {
                try await openProject(project)
            } catch let error as RCNError {
                await send(.errorOccurred(error))
            } catch {
                logService.critical(.unknown(error))
            }

        case let .openWithAppPicked(project, bundleIdentifier):
            updateApplicationBundleIdentifier(bundleIdentifier, for: project)
            projects = userDefaultsRepository.projectsConfiguration.projects

        case .errorOccurred:
            return
        }
    }

    private func addProject(of url: URL) throws {
        guard urlClient.startAccessingSecurityScopedResource(url) else {
            throw RCNError.project(.folderUnreadable)
        }
        defer {
            urlClient.stopAccessingSecurityScopedResource(url)
        }
        guard let bookmark = try? urlClient.bookmarkData(url, .withSecurityScope) else {
            throw RCNError.project(.folderUnreadable)
        }
        var configuration = userDefaultsRepository.projectsConfiguration
        guard !configuration.projects.contains(where: { $0.folderURL == url }) else {
            throw RCNError.project(.duplicateFolder)
        }
        configuration.projects.append(Project(
            id: uuidClient.create(),
            name: url.lastPathComponent,
            folderURL: url,
            bookmark: bookmark,
            applicationBundleIdentifier: defaultApplicationBundleIdentifier,
            createdAt: dateClient.now()
        ))
        userDefaultsRepository.projectsConfiguration = configuration
    }

    private func removeProject(of id: UUID) {
        var configuration = userDefaultsRepository.projectsConfiguration
        configuration.projects.removeAll { $0.id == id }
        userDefaultsRepository.projectsConfiguration = configuration
    }

    private var defaultApplicationBundleIdentifier: String? {
        guard nsWorkspaceClient.urlForApplication("com.microsoft.VSCode") != nil else {
            return nil
        }
        return "com.microsoft.VSCode"
    }

    private func updateApplicationBundleIdentifier(_ bundleIdentifier: String?, for project: Project) {
        var configuration = userDefaultsRepository.projectsConfiguration
        guard let index = configuration.projects.firstIndex(where: { $0.id == project.id }) else {
            return
        }
        configuration.projects[index].applicationBundleIdentifier = bundleIdentifier
        userDefaultsRepository.projectsConfiguration = configuration
    }

    private func openProject(_ project: Project) async throws {
        let (_, url) = try urlClient.create(project.bookmark, .withSecurityScope)
        guard urlClient.startAccessingSecurityScopedResource(url) else {
            throw RCNError.project(.folderUnreadable)
        }
        defer {
            urlClient.stopAccessingSecurityScopedResource(url)
        }
        guard let bundleIdentifier = project.applicationBundleIdentifier,
              let appURL = nsWorkspaceClient.urlForApplication(bundleIdentifier) else {
            _ = nsWorkspaceClient.open(url)
            return
        }
        try await nsWorkspaceClient.openWithApplication([url], appURL)
    }

    private func projectsInheritingDefaultApplication() -> [Project] {
        var configuration = userDefaultsRepository.projectsConfiguration
        let defaultIdentifier = defaultApplicationBundleIdentifier
        var didChange = false
        configuration.projects = configuration.projects.map { project in
            guard project.applicationBundleIdentifier == nil else { return project }
            didChange = true
            var updated = project
            updated.applicationBundleIdentifier = defaultIdentifier
            return updated
        }
        if didChange {
            userDefaultsRepository.projectsConfiguration = configuration
        }
        return configuration.projects
    }

    public enum Action: Sendable {
        case viewAppeared
        case viewDisappeared
        case fileImporterResponse(Result<[URL], any Error>)
        case removeProjectButtonTapped(UUID)
        case removingProjectConfirmed
        case removingProjectCancelled
        case openProjectButtonTapped(Project)
        case openWithAppPicked(Project, String?)
        case errorOccurred(RCNError)
    }
}
