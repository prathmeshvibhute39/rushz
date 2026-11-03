import SwiftUI

/// Account, offline storage and privacy controls.
struct SettingsSheet: View {
    @EnvironmentObject var account: Account
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false
    @State private var confirmDeleteAll = false
    @State private var confirmClearHistory = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                storageSection
                Section {
                    Button("Clear listening history", role: .destructive) { confirmClearHistory = true }
                } header: { Text("Privacy") } footer: {
                    Text("History, playlists and downloads stay on this phone only.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all \(library.tracks.count) downloaded songs?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all downloads", role: .destructive) { library.deleteAll() }
            } message: { Text("You can always stream them again.") }
            .confirmationDialog("Clear your listening history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { History.shared.clear() }
            }
            .fullScreenCover(isPresented: $signingIn) { LoginView() }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: account.isSignedIn ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.system(size: 28)).foregroundStyle(account.isSignedIn ? Color.green : .secondary)
                Text(account.isSignedIn ? "Signed in with Google" : "Not signed in").font(.system(size: 16, weight: .semibold))
            }
            if account.isSignedIn {
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
            } else {
                Button("Sign in with Google") { signingIn = true }
            }
        } header: { Text("Account") } footer: {
            Text(account.isSignedIn
                 ? "YouTube treats Rushz like a signed-in browser, so tracks play, and your home feed and liked songs appear."
                 : "YouTube asks anonymous apps to sign in before it serves audio. Sign in again if playback stops working.")
        }
    }

    private var storageSection: some View {
        Section {
            Toggle("Save songs as I listen", isOn: $library.autoSave)
            Picker("Storage limit", selection: $library.limitMB) {
                ForEach(Library.limitChoicesMB, id: \.self) { mb in
                    Text(mb == 0 ? "No limit" : mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
                }
            }
            LabeledContent("Used", value: "\(ByteCountFormatter.string(fromByteCount: library.usedBytes, countStyle: .file)) · \(library.tracks.count) songs")
            Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
                .disabled(library.tracks.isEmpty)
        } header: { Text("Offline songs") } footer: {
            Text("Once the limit is reached, the songs you played longest ago are removed first. Songs in your playlists are never removed automatically.")
        }
    }
}
