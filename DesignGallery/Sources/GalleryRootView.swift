import SwiftUI

struct GalleryRootView: View {
    @ObservedObject var model: GalleryModel
    @Environment(\.colorScheme) private var colorScheme

    var palette: GalleryPalette {
        .make(theme: model.theme, scheme: colorScheme)
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
        .preferredColorScheme(model.theme == .midnight ? .dark : nil)
    }
}

private struct GalleryControls: View {
    @ObservedObject var model: GalleryModel
    let palette: GalleryPalette

    var body: some View {
        Section {
            Picker("Theme", selection: $model.theme) {
                ForEach(GalleryModel.Theme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .accessibilityHint("Changes the visual theme across the gallery")

            Picker("Fixture", selection: $model.fixture) {
                ForEach(GalleryModel.Fixture.allCases) { fixture in
                    Text(fixture.title).tag(fixture)
                }
            }
            .accessibilityHint("Changes the static Lockbox state shown in the gallery")
        } header: {
            Label("Gallery controls", systemImage: "slider.horizontal.3")
                .foregroundStyle(palette.primary)
        } footer: {
            Text("Static exploration only. Nothing here changes device restrictions or schedules.")
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
