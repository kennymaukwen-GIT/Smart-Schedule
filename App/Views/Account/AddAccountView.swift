import SwiftUI

/// "Add Google account": the user types the address of the Google account whose calendar they want, then signs in on
/// Google's own page with it filled in (`login_hint`). OAuth cannot link an account from an email alone, so the
/// address only steers Google's page; the account Google signs in is compared with it afterwards, and a different
/// one is not stored until the user says so. "Choose from Google's account list" skips the address.
///
/// Opened from every "Add Google account" / "Connect Google Calendar": pushed in the account sheet, a sheet of its
/// own from the drawer and the welcome state (`showsCancel`). Gmail, Google Workspace (school, work) and any other
/// address that is a Google account work; Google's page says when an address is not one.
struct AddAccountView: View {
    /// Presented as its own sheet: a Cancel button closes it (pushed, the back button does).
    var showsCancel = false

    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var showsValidation: Bool
    @State private var isSigningIn = false
    @State private var problem: Problem?
    @State private var mismatch: Mismatch?
    @FocusState private var emailFocused: Bool

    /// Google signed in another account than the one typed.
    struct Mismatch {
        var signedIn: String
        var typed: String
        var pending: GoogleSignInResult
    }

    /// Why the last attempt did not connect anything, and whether "Try again" repeats it.
    struct Problem: Equatable {
        var message: String
        var canRetry: Bool
        /// The email the attempt used (nil: Google's account list).
        var email: String?
    }

    /// The parameters after `showsCancel` are for previews.
    init(showsCancel: Bool = false, email: String = "", showsValidation: Bool = false,
         problem: Problem? = nil, mismatch: Mismatch? = nil) {
        self.showsCancel = showsCancel
        _email = State(initialValue: email)
        _showsValidation = State(initialValue: showsValidation)
        _problem = State(initialValue: problem)
        _mismatch = State(initialValue: mismatch)
    }

    private var isValid: Bool { AccountEmail.isValid(email) }
    private var showsInvalid: Bool { showsValidation && !email.isEmpty && !isValid }

    var body: some View {
        Form {
            Section {
                TextField(text: $email, prompt: Text(verbatim: "example@gmail.com")) {
                    Text("Google account email")
                }
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($emailFocused)
                .disabled(isSigningIn)
                .onSubmit {
                    showsValidation = true
                    if isValid { signIn(email: email) }
                }
            } header: {
                Text("Google account email")
            } footer: {
                if showsInvalid {
                    Label("Enter a full email address, like example@gmail.com", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Gmail, school and work accounts on Google all work. If the address isn't a Google account, Google's page will say so.")
                }
            }

            Section {
                Button {
                    signIn(email: email)
                } label: {
                    HStack(spacing: 8) {
                        if isSigningIn { ProgressView().tint(.black) }
                        Text("Continue with Google")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(isValid && !isSigningIn ? 1 : 0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!isValid || isSigningIn)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Button {
                    signIn(email: nil)
                } label: {
                    Text("Choose from Google's account list")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .disabled(isSigningIn)
                .listRowBackground(Color.clear)
            } footer: {
                Text("You sign in on Google's own page. Smart Schedules never sees your password and only gets access to your calendars.")
            }

            if schedule.isDemo {
                Section {
                    Label("Continuing ends demo mode and removes the sample data.", systemImage: "theatermasks")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let problem {
                Section {
                    Label {
                        Text(verbatim: problem.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if problem.canRetry {
                        Button("Try again") { signIn(email: problem.email) }
                            .disabled(isSigningIn)
                    }
                }
            }
        }
        .navigationTitle("Add Google account")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CancelButton(isShown: showsCancel, isDisabled: isSigningIn) { dismiss() })
        .alert(mismatchTitle, isPresented: Binding(
            get: { mismatch != nil },
            set: { if !$0 { mismatch = nil } }
        ), presenting: mismatch) { found in
            Button("Add \(found.signedIn)") { addSignedIn(found) }
            Button("Try again as \(found.typed)") { retry(as: found) }
            Button("Cancel", role: .cancel) { discard(found) }
        }
        .onChange(of: emailFocused) { _, focused in
            // Checked once the user leaves the field, not while they are still typing.
            if !focused, !email.isEmpty { showsValidation = true }
        }
        .onChange(of: email) {
            if problem != nil { problem = nil }
        }
        .interactiveDismissDisabled(isSigningIn)
        .task {
            // After the push or sheet animation, so the keyboard does not race it.
            try? await Task.sleep(for: .milliseconds(400))
            if email.isEmpty, mismatch == nil, problem == nil { emailFocused = true }
        }
        .preferredColorScheme(.dark)
    }

    private var mismatchTitle: Text {
        Text("You signed in as \(mismatch?.signedIn ?? ""), not \(mismatch?.typed ?? "").")
    }

    // MARK: Actions

    /// - Parameter email: the typed address as Google's login hint; nil opens Google's account chooser.
    private func signIn(email: String?) {
        guard !isSigningIn else { return }
        if let email, !AccountEmail.isValid(email) {
            showsValidation = true
            return
        }
        let hint = email.map(AccountEmail.trimmed)
        emailFocused = false
        problem = nil
        isSigningIn = true
        Task {
            // A real account replaces the sample data (the page says so in demo mode).
            if schedule.isDemo {
                chat.disableDemo()
                await schedule.stopDemo()
            }
            do {
                let outcome = try await schedule.addAccount(email: hint)
                isSigningIn = false
                handle(outcome)
            } catch {
                isSigningIn = false
                let failure = error as? GoogleSignInFailure
                problem = Problem(message: error.localizedDescription, canRetry: failure?.canRetry ?? true, email: hint)
            }
        }
    }

    private func handle(_ outcome: AccountManager.AddOutcome) {
        switch outcome {
        case .connected, .alreadyConnected:
            // The confirmation shows where the user lands (the account sheet or the main screen).
            dismiss()
        case let .mismatch(signedIn, typed, pending):
            mismatch = Mismatch(signedIn: signedIn, typed: typed, pending: pending)
        case .cancelled:
            break // back on this page, as it was
        }
    }

    /// "Add <signed-in email>": keeps the account Google signed in.
    private func addSignedIn(_ found: Mismatch) {
        isSigningIn = true
        Task {
            let outcome = await schedule.addPendingAccount(found.pending)
            isSigningIn = false
            handle(outcome)
        }
    }

    /// "Try again as <typed email>": the other sign-in is dropped (revoked first) and Google’s page
    /// opens again for the typed one.
    private func retry(as found: Mismatch) {
        email = found.typed
        isSigningIn = true
        Task {
            // The revoke finishes first: revoking ends the account's whole grant, so it must not overlap a new
            // sign-in that picks the same account again. Then the alert has finished closing too.
            await schedule.discardPendingAccount(found.pending)
            try? await Task.sleep(for: .milliseconds(300))
            isSigningIn = false
            signIn(email: found.typed)
        }
    }

    /// "Cancel": nothing is added and the grant Google just issued is revoked.
    private func discard(_ found: Mismatch) {
        // Busy until revoked, so a new sign-in cannot overlap the revoke.
        isSigningIn = true
        Task {
            await schedule.discardPendingAccount(found.pending)
            isSigningIn = false
        }
    }
}

/// The sheet's Cancel button. Pushed, the page has the back button instead.
private struct CancelButton: ViewModifier {
    var isShown: Bool
    var isDisabled: Bool
    var action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isShown {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: action)
                        .disabled(isDisabled)
                }
            }
        } else {
            content
        }
    }
}
