import AllocatedUnfairLock
import Foundation

@testable import DataSource

extension UserDefaultsClient {
    struct Storage {
        let lock: AllocatedUnfairLock<[String: Data]>
        let client: UserDefaultsClient

        func currentConfiguration() -> CustomMetricsConfiguration? {
            guard let data = lock.withLock({ $0[.customMetricsConfiguration] }) else {
                return nil
            }
            return try? JSONDecoder().decode(CustomMetricsConfiguration.self, from: data)
        }

        func currentMetricsBarConfiguration() -> MetricsBarConfiguration? {
            guard let data = lock.withLock({ $0[.metricsBarConfiguration] }) else {
                return nil
            }
            return try? JSONDecoder().decode(MetricsBarConfiguration.self, from: data)
        }

        func currentProjectsConfiguration() -> ProjectConfiguration? {
            guard let data = lock.withLock({ $0[.projectsConfiguration] }) else {
                return nil
            }
            return try? JSONDecoder().decode(ProjectConfiguration.self, from: data)
        }
    }

    static func storage(
        initialSources: [CustomMetricsSource] = [],
        initialMetricsBarConfiguration: MetricsBarConfiguration? = nil,
        initialProjects: [Project] = []
    ) -> Storage {
        var initial = [String: Data]()
        if !initialSources.isEmpty,
           let encoded = try? JSONEncoder().encode(CustomMetricsConfiguration(sources: initialSources)) {
            initial[.customMetricsConfiguration] = encoded
        }
        if let initialMetricsBarConfiguration,
           let encoded = try? JSONEncoder().encode(initialMetricsBarConfiguration) {
            initial[.metricsBarConfiguration] = encoded
        }
        if !initialProjects.isEmpty,
           let encoded = try? JSONEncoder().encode(ProjectConfiguration(projects: initialProjects)) {
            initial[.projectsConfiguration] = encoded
        }
        let lock = AllocatedUnfairLock<[String: Data]>(initialState: initial)
        let client = testDependency(of: UserDefaultsClient.self) {
            $0.data = { key in lock.withLock { $0[key] } }
            $0.set = { rawValue, key in
                let dataValue = rawValue as? Data
                lock.withLock { $0[key] = dataValue }
            }
            $0.removeObject = { key in
                lock.withLock { $0[key] = nil }
            }
        }
        return Storage(lock: lock, client: client)
    }
}
