import SwiftUI

/// Settings → General → Permissions. Shows current grant state for
/// each `AppPermission` and exposes per-row "Grant" / "Open System
/// Settings" buttons. Mirror of Onboarding's permissions step,
/// reachable any time after onboarding.
@MainActor
struct PermissionsPanel: View {
    @State private var refreshTick: Int = 0
    @State private var allowMaxToSuggestFeatures = Prefs.allowMaxToSuggestFeatures

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Max never asks for these on launch — you grant them only when you want the corresponding feature. Notifications fires the system dialog the moment you enable it; the others go through System Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(AppPermission.allCases, id: \.self) { perm in
                row(perm)
                    .id("\(perm.rawValue)-\(refreshTick)")
            }

            Divider().padding(.vertical, 6)

            Toggle("Let Max suggest features that aren't enabled", isOn: $allowMaxToSuggestFeatures)
                .onChange(of: allowMaxToSuggestFeatures) { _, new in
                    Prefs.allowMaxToSuggestFeatures = new
                }
            Text("When on (default), Max's prompt includes a short list of optional features that are currently off (voice, autonomy, music-reactive, etc.). He may casually suggest one when the conversation gives a natural opening — never lists, never repeats. Off → Max only knows about features already in use.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            PermissionsCoordinator.refreshNotificationsStatus()
            // Re-render after a beat so the async notifications status
            // lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                refreshTick += 1
            }
        }
    }

    @ViewBuilder
    private func row(_ permission: AppPermission) -> some View {
        let status = PermissionsCoordinator.status(permission)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: status == .granted
                      ? "checkmark.circle.fill"
                      : "exclamationmark.circle")
                    .foregroundStyle(status == .granted ? .green : .orange)
                Text(permission.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                statusLabel(status)
                if status != .granted {
                    Button("Grant") {
                        PermissionsCoordinator.request(permission)
                        refreshTick += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("System Settings") {
                    PermissionsCoordinator.openSystemSettings(permission)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(permission.rationale)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func statusLabel(_ status: PermissionsCoordinator.Status) -> some View {
        switch status {
        case .granted:        Text("Granted").font(.system(size: 11)).foregroundStyle(.green)
        case .denied:         Text("Denied").font(.system(size: 11)).foregroundStyle(.red)
        case .notDetermined:  Text("Not asked").font(.system(size: 11)).foregroundStyle(.secondary)
        case .unknown:        EmptyView()
        }
    }
}
