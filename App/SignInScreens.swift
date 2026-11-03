import SwiftUI
import UserNotifications
import UIKit
import DADFoundation

/// Unauthenticated splash — pick a journey before signing in. The preview store starts
/// signed-in, so this path is exercised only when there is no session.
struct RoleSelect: View {
    let notice: String?
    var invitation: String?
    let onSelect: (AppRole) -> Void
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("auth-notice")
            }
            if let invitation { Text(invitation).font(.body).accessibilityIdentifier("auth-invitation") }
            VStack(spacing: 12) {
                Button("I’m a donor") { analytics?.emit(.roleSelected); onSelect(.donor) }.buttonStyle(DADButtonStyle(.primary))
                Button("I’m a partner") { analytics?.emit(.roleSelected); onSelect(.partner) }.buttonStyle(DADButtonStyle(.secondary))
            }
            if let analytics, analytics.choice == nil { AnalyticsChoice(analytics: analytics) }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("role-select")
    }
}

/// Asks iOS for notification permission only when the donor chooses to, never at launch; once allowed the app
/// registers for a device token (see `PushAppDelegate`).
struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?
    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                Button("Turn on notifications") {
                    Task {
                        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                        if granted { UIApplication.shared.registerForRemoteNotifications() }
                        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("notifications-allow")
            case .denied:
                Text("Notifications are off for DAD in iOS Settings.").font(.footnote).accessibilityIdentifier("notifications-denied")
            default:
                EmptyView()
            }
        }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

/// The first-launch analytics question, worded as on the website; the answer can be changed in Settings.
struct AnalyticsChoice: View {
    let analytics: AnalyticsController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow first-party usage analytics? DAD uses a temporary journey ID to measure signup, sharing and giving. "
                 + "No names, email addresses or payment details are sent. Observations are kept for 13 months. "
                 + "You can change this choice in Settings.").font(.footnote)
            Button("Allow usage analytics") { analytics.choose(true) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-allow")
            Button("Decline usage analytics") { analytics.choose(false) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-decline")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analytics-choice")
    }
}
