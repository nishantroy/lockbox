import SwiftUI

struct GalleryScrollView<Content: View>: View {
    let palette: GalleryPalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.primary)
    }
}

struct GalleryPageHeader: View {
    let eyebrow: String
    let title: String
    let palette: GalleryPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(palette.accent)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GalleryCard<Content: View>: View {
    let palette: GalleryPalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(palette.border.opacity(palette.isDark ? 0.75 : 0.85), lineWidth: 1)
            }
    }
}

/// A visual-only action specimen. Gallery fixtures must never imply that a
/// static preview can change a lock, schedule, or recovery request.
struct GalleryPreviewAction<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), preview only")
            .accessibilityAddTraits(.isStaticText)
    }
}

struct LockboxGalleryView: View {
    @ObservedObject var model: GalleryModel
    let palette: GalleryPalette

    var body: some View {
        GalleryScrollView(palette: palette) {
            GalleryPageHeader(eyebrow: "LOCKBOX", title: model.fixture == .home ? "A calmer phone, when you need it" : activeTitle, palette: palette)

            if model.fixture == .home {
                UnlockedFixtureView(palette: palette)
            } else {
                ActiveFixtureView(fixture: model.fixture, palette: palette)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var activeTitle: String {
        model.fixture == .rest ? "Protect your evening" : "Keep a clear lane"
    }
}

private struct UnlockedFixtureView: View {
    let palette: GalleryPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GalleryPreviewAction(label: "Lock now") {
                HStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(palette.onAccent.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lock now")
                            .font(.title3.weight(.semibold))
                        Text("Choose a finite focus window")
                            .font(.subheadline)
                            .opacity(0.82)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(palette.onAccent)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Label("Tonight", systemImage: "moon.stars.fill")
                            .font(.headline)
                        Spacer()
                        Text("READY")
                            .font(.caption2.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(palette.rest)
                    }
                    Text("Bedtime lock is set")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 0) {
                        ScheduleTime(title: "Starts", value: "10:30 PM", palette: palette)
                        Divider().frame(height: 38).overlay(palette.border)
                        ScheduleTime(title: "Opens", value: "7:00 AM", palette: palette)
                    }
                    GalleryPreviewAction(label: "Start bedtime now") {
                        Label("Start bedtime now", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
            }

            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Your rhythm", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .padding(.bottom, 15)
                    KeyValueRow(label: "Saved rules", value: "Selected essentials", palette: palette)
                    Divider().overlay(palette.border).padding(.vertical, 11)
                    KeyValueRow(label: "Wind-down", value: "On · 30 min before", palette: palette)
                }
            }

            Text("Your phone is ready for a quieter evening.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, -5)
        }
    }
}

private struct ActiveFixtureView: View {
    let fixture: GalleryModel.Fixture
    let palette: GalleryPalette

    private var isRest: Bool { fixture == .rest }
    private var semanticColor: Color { isRest ? palette.rest : palette.focus }
    private var title: String { isRest ? "Get some rest" : "Focus time" }
    private var subtitle: String { isRest ? "Your bedtime session is underway." : "A protected lane for the work in front of you." }
    private var end: String { isRest ? "Tomorrow · 7:00 AM" : "Today · 4:30 PM" }
    private var origin: String { isRest ? "Bedtime schedule" : "Started manually" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 13) {
                        Image(systemName: isRest ? "moon.stars.fill" : "sparkles")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 48, height: 48)
                            .background(semanticColor, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.title2.weight(.semibold))
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(palette.secondary)
                        }
                    }
                    Divider().overlay(palette.border)
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("OPENS")
                                .font(.caption2.weight(.bold))
                                .tracking(1.1)
                                .foregroundStyle(palette.secondary)
                            Text(end)
                                .font(.headline)
                        }
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(semanticColor)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(subtitle) Opens \(end).")

            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    Label("This lock", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .padding(.bottom, 15)
                    KeyValueRow(label: "Opens", value: end, palette: palette)
                    Divider().overlay(palette.border).padding(.vertical, 11)
                    KeyValueRow(label: "Started by", value: origin, palette: palette)
                }
            }

            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Need to end early?", systemImage: "arrow.uturn.backward.circle")
                        .font(.headline)
                    Text("Recovery waits 15 minutes, then asks you to confirm. Waiting alone never unlocks your phone.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                    GalleryPreviewAction(label: "Start recovery") {
                        Text("Start recovery")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
            }

            GalleryCard(palette: palette) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changes after this lock")
                            .font(.subheadline.weight(.semibold))
                        Text("New bedtime settings will take effect after this session ends.")
                            .font(.footnote)
                            .foregroundStyle(palette.secondary)
                    }
                }
            }
        }
    }
}

private struct ScheduleTime: View {
    let title: String
    let value: String
    let palette: GalleryPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(palette.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String
    let palette: GalleryPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

struct PeopleGalleryView: View {
    let palette: GalleryPalette

    var body: some View {
        GalleryScrollView(palette: palette) {
            GalleryPageHeader(eyebrow: "PEOPLE", title: "A trusted person can help", palette: palette)
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Private recovery, by design", systemImage: "person.2.fill")
                        .font(.headline)
                    Text("Phone Lockbox is designed for an honest recovery relationship—not a social feed or a remote control.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Label("Current availability", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                        Spacer()
                        Text("NOT CONNECTED")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(palette.secondary)
                    }
                    Text("Remote approvals are unavailable until an authenticated, durable relay exists. No approval action is offered here yet.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondary)
                }
            }
            GalleryCard(palette: palette) {
                VStack(alignment: .leading, spacing: 15) {
                    Label("How it is intended to work", systemImage: "sparkles")
                        .font(.headline)
                    ExplanationRow(icon: "iphone", title: "Same-app pairing", text: "Mutually confirmed, device-held identities. No email or hosted account.", palette: palette)
                    ExplanationRow(icon: "checkmark.shield", title: "Exact-lock intent", text: "A trusted person may eventually approve release of one exact current session—not start or extend it.", palette: palette)
                    ExplanationRow(icon: "lock.privacy", title: "Private by design", text: "App selections and usage are not shared. Delayed recovery stays on this device.", palette: palette)
                }
            }
        }
    }
}

private struct ExplanationRow: View {
    let icon: String
    let title: String
    let text: String
    let palette: GalleryPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(palette.secondary)
            }
        }
    }
}
