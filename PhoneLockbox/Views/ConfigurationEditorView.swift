import SwiftUI
import FamilyControls

struct ConfigurationEditorView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator
    let isInitialSetup: Bool
    @State private var showingPicker = false
    @State private var draftSelection = FamilyActivitySelection(includeEntireCategory: true)

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: isInitialSetup ? "Set up bedtime" : "Bedtime rules")

            if isInitialSetup {
                LockboxCard {
                    Text("Choose the rules Phone Lockbox will use during the saved bedtime window.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Restriction", systemImage: "slider.horizontal.3")
                    Picker("Mode", selection: modeBinding) {
                        ForEach(ScreenTimeCoordinator.RestrictionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!coordinator.canEditDraft)
                    Text(coordinator.mode == .blockSelected
                         ? "Selected apps, categories, and websites will be blocked."
                         : "Everything except selected apps will be blocked. Allow-only mode needs at least one app token.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Bedtime window", systemImage: "calendar.badge.clock")
                    DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                        .disabled(!coordinator.canEditDraft)
                    DatePicker("Ends", selection: endBinding, displayedComponents: .hourAndMinute)
                        .disabled(!coordinator.canEditDraft)
                    Text("Repeats daily and may cross midnight. The saved window must be at least 15 minutes; the system remains authoritative about delivery.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Apps and websites", systemImage: "square.grid.2x2")
                    Button {
                        draftSelection = coordinator.selection
                        showingPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Text("Choose apps or categories")
                            Spacer()
                            Text("\(coordinator.selectedItemCount) selected")
                                .foregroundStyle(LockboxTheme.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LockboxTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!coordinator.canEditDraft)
                    .accessibilityLabel("Choose apps, categories, or websites")
                    Text(coordinator.mode == .blockSelected
                         ? "Choose individual apps, categories, or websites to block."
                         : "Choose apps, categories, or websites to allow. Categories are expanded to their apps.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    if coordinator.mode == .allowOnlySelected && coordinator.selectedItemCount > 0 && !coordinator.canApplySelection {
                        Label("Allow-only mode needs at least one app token.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    Button(isInitialSetup ? "Save and register bedtime schedule" : "Save bedtime rules") {
                        coordinator.saveConfiguration(start: coordinator.startComponents, end: coordinator.endComponents)
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(!coordinator.canApplySelection || !coordinator.isAuthorized)
                    Text("Saving validates this policy before requesting the OS schedule. A successful request is not proof that every app is blocked or that callbacks arrive on time.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            if let error = coordinator.lastError {
                LockboxCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.destructive)
                }
            }
        }
        .lockboxScreen()
        .onAppear {
            draftSelection = coordinator.selection
        }
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                FamilyActivityPicker(selection: $draftSelection)
                    .navigationTitle("Choose apps")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showingPicker = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                coordinator.commitSelection(draftSelection)
                                showingPicker = false
                            }
                        }
                    }
            }
            .lockboxScreen()
        }
    }

    private var modeBinding: Binding<ScreenTimeCoordinator.RestrictionMode> {
        Binding(
            get: { coordinator.mode },
            set: { coordinator.setDraftMode($0) }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { date(from: coordinator.startComponents) },
            set: { coordinator.setDraftStart($0) }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { date(from: coordinator.endComponents) },
            set: { coordinator.setDraftEnd($0) }
        )
    }

    private func date(from components: DateComponents) -> Date {
        Calendar.current.date(from: DateComponents(hour: components.hour ?? 0, minute: components.minute ?? 0)) ?? .now
    }
}
