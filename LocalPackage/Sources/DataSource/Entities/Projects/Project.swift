/*
 Project.swift
 DataSource

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

import Foundation

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var folderURL: URL
    public var bookmark: Data
    public var applicationBundleIdentifier: String?
    public var createdAt: Date

    public init(
        id: UUID,
        name: String,
        folderURL: URL,
        bookmark: Data,
        applicationBundleIdentifier: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.bookmark = bookmark
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.createdAt = createdAt
    }
}
