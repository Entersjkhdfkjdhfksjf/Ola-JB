import SwiftUI

struct ContentView: View {
    @State private var address: String = ""
    @State private var shellCommand: String = ""
    @State private var log: String = ""
    @State private var client: ScooterClient?
    @State private var connecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("S1 Toolkit").font(.title2).bold()

                TextField("fe80::xxxx:xxxx:xxxx:xxxx%en0", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button(connecting ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting || address.isEmpty)

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
