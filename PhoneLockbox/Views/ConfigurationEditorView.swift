import SwiftUI
import FamilyControls

struct ConfigurationEditorView: View {
    enum Sections { case all, restrictions }

    @ObservedObject var coordinator: ScreenTimeCoordinator
    let isInitialSetup: Bool
    /// `.restrictions` shows mode, apps and Save only; the bedtime times live
    /// in `BedtimeScheduleView`. Initial setup always shows everything.
    var sections: Sections = .all
    @State private var showingPicker = false
    @State private var draftSelection = FamilyActivitySelection(includeEntireCategory: true)

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: isInitialSetup ? "Set up bedtime" : (showsTimes ? "Bedtime rules" : "What gets blocked"))

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
                         ? "Selected apps, categories and websites are blocked."
                         : "Everything except your selection is blocked, so choose at least one app.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            if showsTimes {
            LockboxCard {
                VStack(alignment: .leading, spacing: 14) {
                    LockboxSectionLabel("Bedtime window", systemImage: "calendar.badge.clock")
                    DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                        .disabled(!coordinator.canEditDraft)
                    DatePicker("Ends", selection: endBinding, displayedComponents: .hourAndMinute)
                        .disabled(!coordinator.canEditDraft)
                    Text("Repeats every night and may cross midnight; at least 15 minutes.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                }
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
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!coordinator.canEditDraft)
                    .accessibilityLabel("Choose apps, categories, or websites")
                    Text(coordinator.mode == .blockSelected
                         ? "Choose apps, categories or websites to block."
                         : "Choose apps, categories or websites to allow.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                    if coordinator.mode == .allowOnlySelected && coordinator.selectedItemCount > 0 && !coordinator.canApplySelection {
                        Label("Allow-only mode needs at least one app token.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(LockboxTheme.attention)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    Button(isInitialSetup ? "Save and register bedtime schedule" : (showsTimes ? "Save bedtime rules" : "Save")) {
                        if showsTimes {
                            coordinator.saveConfiguration(start: coordinator.startComponents, end: coordinator.endComponents)
                        } else {
                            // Times are edited elsewhere; keep the last saved ones,
                            // and never turn bedtime on from here.
                            coordinator.saveRestrictions()
                        }
                    }
                    .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                    .disabled(!coordinator.canApplySelection || !coordinator.isAuthorized)
                    if coordinator.hasActiveLock {
                        Text("Changes apply after this lock ends.")
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                    if let pending = coordinator.pendingChangesSummary {
                        Text(pending)
                            .font(.subheadline)
                            .foregroundStyle(LockboxTheme.secondary)
                    }
                    Text("The system decides when, and whether, apps are blocked.")
                        .font(.subheadline)
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

    private var showsTimes: Bool { isInitialSetup || sections == .all }

    private func date(from components: DateComponents) -> Date {
        LockboxClockTime.date(from: components)
    }
}
