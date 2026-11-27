import SwiftUI

struct ContentView: View {
    @State private var address: String = ""
    @State private var shellCommand: String = ""
    @State private var log: String = ""
    @State private var client: ScooterClient?
    @State private var connecting = false
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("S1 Toolkit").font(.title2).bold()

                TextField("fe80::xxxx:xxxx:xxxx:xxxx%en0", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                HStack {
                    Button(scanning ? "Scanning…" : "Scan for scooter") { scan() }
                        .buttonStyle(.bordered)
                        .disabled(scanning)
                    Button(connecting ? "Connecting…" : "Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || address.isEmpty)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    actionButton("Settings") { try await $0.openIntent("android.settings.SETTINGS") }
                    actionButton("Wi-Fi") { try await $0.openIntent("android.settings.WIFI_SETTINGS") }
                    actionButton("Browser") { try await openBrowser($0) }
                    actionButton("Home (dash)") { try await $0.openComponent("com.olaelectric.hmiclient/.MainActivity") }
                    actionButton("Back key") { try await $0.sendKeyEvent(4) }
                    actionButton("Device info") { try await $0.exec("getprop ro.build.version.release") }
                }

                HStack {
                    TextField("root shell command", text: $shellCommand)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Run") {
                        let cmd = shellCommand
                        guard !cmd.isEmpty else { return }
                        run(label: "shell: \(cmd)") { try await $0.shell(cmd) }
                    }
                    .buttonStyle(.bordered)
                }

                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                    .padding(8)
                    .background(Color.black)
                    .cornerRadius(8)
            }
            .padding()
        }
    }

    private func actionButton(_ title: String, _ action: @escaping (ScooterClient) async throws -> (status: Int, message: String)) -> some View {
        Button(title) { run(label: title, action) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func scan() {
        scanning = true
        appendLog("Scanning the current Wi-Fi link for the scooter...")
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                NeighborScanner.findCandidates()
            }.value

            if candidates.isEmpty {
                appendLog("No IPv6 neighbors found. Make sure your iPhone and the scooter " +
                          "are on the same Wi-Fi/hotspot, then try again -- or type the " +
                          "address in manually.")
                scanning = false
                return
            }

            appendLog("Found \(candidates.count) candidate(s), checking each for the scooter's service...")
            for candidate in candidates {
                appendLog("  trying \(candidate.address) ...")
                let c = ScooterClient(host: candidate.address)
                do {
                    try await c.connect(timeoutSeconds: 2)
                    client?.close()
                    client = c
                    address = candidate.address
                    appendLog("Found it: \(candidate.address). Connected.")
                    scanning = false
                    return
                } catch {
                    c.close()
                    // not the scooter, or not answering -- try the next candidate
                }
            }
            appendLog("None of the candidates answered on the scooter's service. " +
                      "It may not be awake, or not on this network yet.")
            scanning = false
        }
    }

    private func connect() {
        connecting = true
        appendLog("Connecting to \(address) ...")
        Task {
            do {
                client?.close()
                let c = ScooterClient(host: address)
                try await c.connect()
                client = c
                appendLog("Connected.")
            } catch {
                appendLog("Connection failed: \(error.localizedDescription)")
            }
            connecting = false
        }
    }

    private func run(label: String, _ action: @escaping (ScooterClient) async throws -> (status: Int, message: String)) {
        guard let client else {
            appendLog("Connect first.")
            return
        }
        appendLog("-> \(label)")
        Task {
            do {
                let (status, message) = try await action(client)
                appendLog("   status=\(status) \(message.prefix(300))")
            } catch {
                appendLog("   error: \(error.localizedDescription)")
            }
        }
    }

    private func openBrowser(_ client: ScooterClient) async throws -> (status: Int, message: String) {
        for component in ["com.android.browser/.BrowserActivity", "com.android.htmlviewer/.HTMLViewerActivity"] {
            let result = try await client.openComponent(component)
            if result.status == 0 || result.status == 1 { return result }
        }
        return try await client.openIntent("android.intent.action.VIEW")
    }

    private func appendLog(_ line: String) {
        log += line + "\n"
    }
}

#Preview {
    ContentView()
}
