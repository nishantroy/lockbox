import SwiftUI

struct GalleryRootView: View {
    @ObservedObject var model: GalleryModel
    @Environment(\.colorScheme) private var colorScheme

    var palette: GalleryPalette {
        .make(theme: model.theme, scheme: colorScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch model.theme {
        case .midnight, .midnightOriginal, .midnightContrast:
            .dark
        case .adaptivePreview:
            model.appearance == .dark ? .dark : .light
        case .circadian, .lantern:
            nil
        }
    }

    var body: some View {
        TabView {
            NavigationStack {
                LockboxGalleryView(model: model, palette: palette)
            }
            .tabItem { Label("Lockbox", systemImage: "lock.shield") }

            NavigationStack {
                PeopleGalleryView(palette: palette)
            }
            .tabItem { Label("People", systemImage: "person.2") }

            NavigationStack {
                SettingsGalleryView(model: model, palette: palette)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(palette.accent)
        .background(palette.background)
        .preferredColorScheme(preferredScheme)
    }
}

private struct GalleryControls: View {
    @ObservedObject var model: GalleryModel
    let palette: GalleryPalette

    var body: some View {
        Section {
            Picker("Theme", selection: $model.theme) {
                Section("Round 1 references") {
                    ForEach(GalleryModel.Theme.round1) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Section("Round 2 choices") {
                    ForEach(GalleryModel.Theme.round2) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }
            .accessibilityHint("Choose a round 1 reference or round 2 gallery-only direction")

            Picker("Fixture", selection: $model.fixture) {
                ForEach(GalleryModel.Fixture.allCases) { fixture in
                    Text(fixture.title).tag(fixture)
                }
            }
            .accessibilityHint("Changes the static Lockbox state shown in the gallery")

            if model.theme.isAdaptivePreview {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(GalleryModel.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityHint("Inspects the future Adaptive Preview in dark or light appearance")
                Text("Adaptive Preview is a future gallery direction; production remains always dark.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
            }
        } header: {
            Label("Gallery controls", systemImage: "slider.horizontal.3")
                .foregroundStyle(palette.primary)
        } footer: {
            Text("Static exploration only. Nothing here changes device restrictions or schedules. Production preference: always dark.")
        }
    }
}

struct SettingsGalleryView: View {
    @ObservedObject var model: GalleryModel
    let palette: GalleryPalette

    var body: some View {
        GalleryScrollView(palette: palette) {
            GalleryPageHeader(eyebrow: "SETTINGS", title: "Make it fit your rhythm", palette: palette)
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Bedtime schedule", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    LabeledContent("Window", value: "10:30 PM – 7:00 AM")
                    LabeledContent("Restrictions", value: "Selected essentials")
                    Text("A single saved window keeps the ritual simple. Changes during an active lock wait until it ends.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Recovery", systemImage: "arrow.uturn.backward.circle")
                        .font(.headline)
                    LabeledContent("Wait", value: "15 minutes")
                    Text("Recovery always asks for an explicit confirmation and never disables future bedtime sessions.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Wind-down", systemImage: "bell.badge")
                        .font(.headline)
                    LabeledContent("Reminders", value: "On · 30 minutes before")
                    Text("Wind-down follows the saved bedtime start; it is not a second bedtime clock.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Live Activity", systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.headline)
                    LabeledContent("Status", value: "On when available")
                    Text("A best-effort status surface. It never enforces, releases, or proves restrictions changed.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryControls(model: model, palette: palette)
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Developer", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    Text("Prototype diagnostics and cleanup tools live here in the real app. This visual gallery intentionally has no device behavior.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbarBackground(palette.background, for: .navigationBar)
    }
}
