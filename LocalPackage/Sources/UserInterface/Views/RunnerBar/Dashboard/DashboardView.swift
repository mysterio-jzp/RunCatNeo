/*
 DashboardView.swift
 UserInterface

 Created by Takuto Nakamura on 2026/05/08.
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
import Model
import SwiftUI

struct DashboardView: View {
    @Environment(\.appDependencies) private var appDependencies
    @StateObject var store: Dashboard
    @State private var moveInFromTrailing = true
    @Namespace private var tabNamespace

    private let tabTransitionAnimation = Animation.spring(
        response: 0.42,
        dampingFraction: 0.72,
        blendDuration: 0.15
    )

    private func tabBackground(_ isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Capsule()
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .matchedGeometryEffect(id: "selected-tab", in: tabNamespace)
                    .keyframeAnimator(initialValue: 1.0, trigger: store.selectedTab) { content, scale in
                        content.scaleEffect(x: scale, y: 1)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(0.75, duration: 0.14)
                            SpringKeyframe(1.0, duration: 0.28)
                        }
                    }
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(store.appName)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer()
                MenuView(store: store)
            }
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Button {
                        Task {
                            await store.send(.tabSelected(tab))
                        }
                    } label: {
                        Text(tab.localizedName)
                            .font(.system(size: 12, weight: store.selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(store.selectedTab == tab ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 22)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                            .background(tabBackground(store.selectedTab == tab))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(3)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            }
            Group {
                switch store.selectedTab {
                case .system:
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            SystemInfoStackView(
                                systemInfoBundle: store.systemInfoBundle,
                                cpuRingBuffer: store.cpuRingBuffer,
                                memoryRingBuffer: store.memoryRingBuffer,
                                isPreview: store.isPreview
                            )
                            ForEach(store.customMetricsBundles) { customMetricsBundle in
                                CustomMetricsCardView(
                                    customMetricsBundle: customMetricsBundle,
                                    displayedDate: store.displayedDate
                                )
                            }
                        }
                    }
                case .projects:
                    ProjectsDashboardView(store: store.projects)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: moveInFromTrailing ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: moveInFromTrailing ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .padding(8)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .animation(tabTransitionAnimation, value: store.selectedTab)
        .alert(
            isPresented: $store.showingAlert,
            error: store.error,
            actions: { _ in },
            message: { _ in }
        )
        .task {
            await store.send(.viewAppeared(String(describing: Self.self)))
        }
        .onChange(of: store.selectedTab) { oldValue, newValue in
            let tabs = DashboardTab.allCases
            if let oldIndex = tabs.firstIndex(of: oldValue),
               let newIndex = tabs.firstIndex(of: newValue) {
                moveInFromTrailing = newIndex > oldIndex
            }
        }
        .onDisappear {
            Task {
                await store.send(.viewDisappeared)
            }
        }
    }
}

extension Dashboard: ObservableObject {}
