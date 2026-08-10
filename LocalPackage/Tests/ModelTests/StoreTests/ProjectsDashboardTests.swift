import AllocatedUnfairLock
import Foundation
import Testing

@testable import DataSource
@testable import Model

struct ProjectsDashboardTests {
    private func makeProject(
        id: Int,
        name: String = "Project",
        folderPath: String = "/tmp/project",
        bookmark: Data = Data([0x42]),
        applicationBundleIdentifier: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Project {
        Project(
            id: UUID(id),
            name: name,
            folderURL: URL(filePath: folderPath),
            bookmark: bookmark,
            applicationBundleIdentifier: applicationBundleIdentifier,
            createdAt: createdAt
        )
    }

    private func errorRecorder() -> (
        lock: AllocatedUnfairLock<RCNError?>,
        action: (ProjectsDashboard.Action) async -> Void
    ) {
        let lock = AllocatedUnfairLock<RCNError?>(initialState: nil)
        let action: (ProjectsDashboard.Action) async -> Void = { action in
            if case let .errorOccurred(error) = action {
                lock.withLock { $0 = error }
            }
        }
        return (lock, action)
    }

    @MainActor @Test
    func send_viewAppeared_loads_projects_from_user_defaults() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 1, name: "Existing")
        ])
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        #expect(sut.projects.count == 1)
        #expect(sut.projects.first?.name == "Existing")
    }

    @MainActor @Test
    func send_viewAppeared_migrates_legacy_projects_to_installed_vscode() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 1, name: "Legacy")
        ])
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in URL(filePath: "/Applications/Visual Studio Code.app") }
        }
        let sut = ProjectsDashboard(.testDependencies(
            nsWorkspaceClient: nsWorkspaceClient,
            userDefaultsClient: storage.client
        ))
        await sut.send(.viewAppeared)
        #expect(sut.projects.first?.applicationBundleIdentifier == "com.microsoft.VSCode")
        #expect(storage.currentProjectsConfiguration()?.projects.first?.applicationBundleIdentifier
            == "com.microsoft.VSCode")
    }

    @MainActor @Test
    func send_fileImporterResponse_success_appends_project_and_persists() async {
        let appState = AllocatedUnfairLock<AppState>(initialState: .init())
        let storage = UserDefaultsClient.storage()
        let folderURL = URL(filePath: "/tmp/new-project")
        let urlClient = testDependency(of: URLClient.self) {
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
            $0.bookmarkData = { _, _ in Data([0xAB]) }
        }
        let sut = ProjectsDashboard(.testDependencies(
            appStateClient: .testDependency(appState),
            urlClient: urlClient,
            userDefaultsClient: storage.client
        ))
        await sut.send(.fileImporterResponse(.success([folderURL])))
        #expect(sut.projects.count == 1)
        let project = sut.projects.first
        #expect(project?.name == "new-project")
        #expect(project?.folderURL == folderURL)
        #expect(project?.bookmark == Data([0xAB]))
        #expect(project?.applicationBundleIdentifier == nil)
        #expect(storage.currentProjectsConfiguration()?.projects.map(\.id) == sut.projects.map(\.id))
    }

    @MainActor @Test
    func send_fileImporterResponse_success_defaults_to_installed_vscode() async {
        let appState = AllocatedUnfairLock<AppState>(initialState: .init())
        let storage = UserDefaultsClient.storage()
        let vscodeAppURL = URL(filePath: "/Applications/Visual Studio Code.app")
        let urlClient = testDependency(of: URLClient.self) {
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
            $0.bookmarkData = { _, _ in Data([0xAB]) }
        }
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in vscodeAppURL }
        }
        let sut = ProjectsDashboard(.testDependencies(
            appStateClient: .testDependency(appState),
            nsWorkspaceClient: nsWorkspaceClient,
            urlClient: urlClient,
            userDefaultsClient: storage.client
        ))
        await sut.send(.fileImporterResponse(.success([URL(filePath: "/tmp/another")])))
        #expect(sut.projects.first?.applicationBundleIdentifier == "com.microsoft.VSCode")
    }

    @MainActor @Test
    func send_fileImporterResponse_duplicate_folder_forwards_error() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 1, folderPath: "/tmp/dup")
        ])
        let recorder = errorRecorder()
        let urlClient = testDependency(of: URLClient.self) {
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
            $0.bookmarkData = { _, _ in Data([0xAB]) }
        }
        let sut = ProjectsDashboard(
            .testDependencies(urlClient: urlClient, userDefaultsClient: storage.client),
            action: recorder.action
        )
        await sut.send(.fileImporterResponse(.success([URL(filePath: "/tmp/dup")])))
        #expect(recorder.lock.withLock(\.self) == .project(.duplicateFolder))
        #expect(sut.projects.count == 1)
    }

    @MainActor @Test
    func send_fileImporterResponse_unaccessible_folder_forwards_error() async {
        let storage = UserDefaultsClient.storage()
        let recorder = errorRecorder()
        let urlClient = testDependency(of: URLClient.self) {
            $0.startAccessingSecurityScopedResource = { _ in false }
        }
        let sut = ProjectsDashboard(
            .testDependencies(urlClient: urlClient, userDefaultsClient: storage.client),
            action: recorder.action
        )
        await sut.send(.fileImporterResponse(.success([URL(filePath: "/tmp/denied")])))
        #expect(recorder.lock.withLock(\.self) == .project(.folderUnreadable))
        #expect(sut.projects.isEmpty)
    }

    @MainActor @Test
    func send_fileImporterResponse_success_without_url_is_noop() async {
        let storage = UserDefaultsClient.storage()
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.fileImporterResponse(.success([])))
        #expect(sut.projects.isEmpty)
    }

    @MainActor @Test
    func send_fileImporterResponse_failure_does_not_throw() async {
        struct DummyError: Error {}
        let sut = ProjectsDashboard(.testDependencies())
        await sut.send(.fileImporterResponse(.failure(DummyError())))
        #expect(sut.projects.isEmpty)
    }

    @MainActor @Test
    func send_removeProjectButtonTapped_marks_pending_and_shows_dialog() async {
        let existingID = UUID(2)
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 2, name: "Pending")
        ])
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.removeProjectButtonTapped(existingID))
        #expect(sut.pendingRemovalProjectID == existingID)
        #expect(sut.showingConfirmationDialog)
        #expect(sut.projects.count == 1)
    }

    @MainActor @Test
    func send_removingProjectConfirmed_removes_project_and_persists() async {
        let existingID = UUID(3)
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 3, name: "Doomed")
        ])
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.removeProjectButtonTapped(existingID))
        await sut.send(.removingProjectConfirmed)
        #expect(sut.projects.isEmpty)
        #expect(sut.pendingRemovalProjectID == nil)
        #expect(storage.currentProjectsConfiguration()?.projects.isEmpty == true)
    }

    @MainActor @Test
    func send_removingProjectConfirmed_with_no_pending_is_noop() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 4, name: "Safe")
        ])
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.removingProjectConfirmed)
        #expect(sut.projects.count == 1)
    }

    @MainActor @Test
    func send_removingProjectCancelled_clears_pending_without_removing() async {
        let existingID = UUID(5)
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 5, name: "Spared")
        ])
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.removeProjectButtonTapped(existingID))
        await sut.send(.removingProjectCancelled)
        #expect(sut.pendingRemovalProjectID == nil)
        #expect(sut.projects.count == 1)
    }

    @MainActor @Test
    func send_openWithAppPicked_updates_and_persists_application() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 6, name: "First")
        ])
        let project = makeProject(id: 6, name: "First")
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.openWithAppPicked(project, "dev.warp.Warp-Stable"))
        #expect(storage.currentProjectsConfiguration()?.projects.first?.applicationBundleIdentifier
            == "dev.warp.Warp-Stable")
        #expect(sut.projects.first?.applicationBundleIdentifier == "dev.warp.Warp-Stable")
    }

    @MainActor @Test
    func send_openWithAppPicked_with_nil_clears_application() async {
        let storage = UserDefaultsClient.storage(initialProjects: [
            makeProject(id: 6, name: "First", applicationBundleIdentifier: "com.microsoft.VSCode")
        ])
        let project = makeProject(id: 6, name: "First", applicationBundleIdentifier: "com.microsoft.VSCode")
        let sut = ProjectsDashboard(.testDependencies(userDefaultsClient: storage.client))
        await sut.send(.viewAppeared)
        await sut.send(.openWithAppPicked(project, nil))
        #expect(storage.currentProjectsConfiguration()?.projects.first?.applicationBundleIdentifier == nil)
    }

    @MainActor @Test
    func send_openProjectButtonTapped_opens_folder_in_application() async {
        let appURL = URL(filePath: "/Applications/Visual Studio Code.app")
        let openedURLs = AllocatedUnfairLock<[URL]>(initialState: [])
        let openedAppURLs = AllocatedUnfairLock<[URL]>(initialState: [])
        let project = makeProject(
            id: 7,
            name: "First",
            folderPath: "/tmp/first",
            applicationBundleIdentifier: "com.microsoft.VSCode"
        )
        let urlClient = testDependency(of: URLClient.self) {
            $0.create = { _, _ in (false, project.folderURL) }
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
        }
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in appURL }
            $0.openWithApplication = { urls, appURL in
                openedURLs.withLock { $0 = urls }
                openedAppURLs.withLock { $0 = [appURL] }
            }
        }
        let sut = ProjectsDashboard(.testDependencies(
            nsWorkspaceClient: nsWorkspaceClient,
            urlClient: urlClient
        ))
        await sut.send(.openProjectButtonTapped(project))
        #expect(openedURLs.withLock(\.self) == [project.folderURL])
        #expect(openedAppURLs.withLock(\.self) == [appURL])
    }

    @MainActor @Test
    func send_openProjectButtonTapped_opens_folder_even_when_application_running() async {
        let openedURLs = AllocatedUnfairLock<[URL]>(initialState: [])
        let opened = AllocatedUnfairLock<Bool>(initialState: false)
        let project = makeProject(
            id: 7,
            name: "First",
            folderPath: "/tmp/first",
            applicationBundleIdentifier: "com.microsoft.VSCode"
        )
        let urlClient = testDependency(of: URLClient.self) {
            $0.create = { _, _ in (false, project.folderURL) }
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
        }
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in URL(filePath: "/Applications/Visual Studio Code.app") }
            $0.openWithApplication = { urls, _ in
                openedURLs.withLock { $0 = urls }
                opened.withLock { $0 = true }
            }
        }
        let sut = ProjectsDashboard(.testDependencies(
            nsWorkspaceClient: nsWorkspaceClient,
            urlClient: urlClient
        ))
        await sut.send(.openProjectButtonTapped(project))
        #expect(openedURLs.withLock(\.self) == [project.folderURL])
        #expect(opened.withLock(\.self) == true)
    }

    @MainActor @Test
    func send_openProjectButtonTapped_uses_system_default_when_no_application_configured() async {
        let openedURLs = AllocatedUnfairLock<[URL]>(initialState: [])
        let project = makeProject(id: 7, name: "First", folderPath: "/tmp/first")
        let urlClient = testDependency(of: URLClient.self) {
            $0.create = { _, _ in (false, project.folderURL) }
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
        }
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in nil }
            $0.open = { url in
                openedURLs.withLock { $0 = [url] }
                return true
            }
        }
        let sut = ProjectsDashboard(.testDependencies(
            nsWorkspaceClient: nsWorkspaceClient,
            urlClient: urlClient
        ))
        await sut.send(.openProjectButtonTapped(project))
        #expect(openedURLs.withLock(\.self) == [project.folderURL])
    }

    @MainActor @Test
    func send_openProjectButtonTapped_uses_system_default_when_configured_app_missing() async {
        let openedURLs = AllocatedUnfairLock<[URL]>(initialState: [])
        let project = makeProject(
            id: 7,
            name: "First",
            folderPath: "/tmp/first",
            applicationBundleIdentifier: "dev.gone.Missing"
        )
        let urlClient = testDependency(of: URLClient.self) {
            $0.create = { _, _ in (false, project.folderURL) }
            $0.startAccessingSecurityScopedResource = { _ in true }
            $0.stopAccessingSecurityScopedResource = { _ in }
        }
        let nsWorkspaceClient = testDependency(of: NSWorkspaceClient.self) {
            $0.urlForApplication = { _ in nil }
            $0.open = { url in
                openedURLs.withLock { $0 = [url] }
                return true
            }
        }
        let sut = ProjectsDashboard(.testDependencies(
            nsWorkspaceClient: nsWorkspaceClient,
            urlClient: urlClient
        ))
        await sut.send(.openProjectButtonTapped(project))
        #expect(openedURLs.withLock(\.self) == [project.folderURL])
    }
}