import RDPManagerCore
import SwiftUI

/// Commands for a running session, shared by the sidebar, the Overview table and the tab strip,
/// so a session can be controlled from wherever its connection is. Windows actions appear
/// only for RDP sessions, terminal actions only for SSH sessions.
struct SessionControlMenuItems: View {
    let session: WorkspaceSession
    var showsShowSession = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = session.status.isActive
        let inProgress = session.status.isInProgress
        if showsShowSession {
            Button("Show Session") { model.workspace.show(session) }
        }
        Button("Reconnect") { session.connect() }
            .disabled(inProgress)
        Button("Disconnect") { session.disconnect() }
            .disabled(active == false && inProgress == false && session.status.tone != .needsUser)
        Divider()
        switch session {
        case let .rdp(rdp):
            Button("Send Ctrl+Alt+Del") { rdp.sendCtrlAltDelete() }
                .disabled(active == false)
            Button("Sign Out of Windows…") {
                if confirmSignOut(rdp) { rdp.signOut() }
            }
            .disabled(active == false || rdp.isSigningOut)
        case let .ssh(ssh):
            Button("Send Interrupt (Ctrl-C)") { ssh.sendInterrupt() }
                .disabled(active == false)
            Button("Clear Scrollback") { ssh.clearScrollback() }
        }
        Divider()
        Button("Close Session") { model.workspace.close(session) }
    }
}

/// The session commands for every session open for a connection: inline for one, a submenu
/// per session for several.
struct ConnectionSessionsMenuItems: View {
    let connectionID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.workspace.sessions(for: connectionID)
        if sessions.count == 1, let session = sessions.first {
            Divider()
            SessionControlMenuItems(session: session)
        } else if sessions.count > 1 {
            Divider()
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                Menu("Session \(index + 1) — \(session.status.label)") {
                    SessionControlMenuItems(session: session)
                }
            }
        }
    }
}
