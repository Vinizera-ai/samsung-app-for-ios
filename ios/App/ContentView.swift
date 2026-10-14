import Fit3Kit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var band: BandManager
    @State private var showScanner = false
    @State private var title = "Olá do iPhone"
    @State private var message = "Notificação personalizada do Fit3 Link"
    @AppStorage("calls.enabled") private var callsEnabled = true
    @AppStorage("calls.missed") private var missedEnabled = true
    @State private var keepAlive = KeepAlive.shared.enabled

    var body: some View {
        NavigationStack {
            List {
                Section { statusRow }

                if !band.hasBand {
                    Section {
                        Button("Procurar minha Galaxy Fit3") { showScanner = true }
                    } footer: {
                        Text("Se a pulseira estava pareada com um Android, desligue o Bluetooth dele ou redefina a pulseira (Configurações › Geral › Redefinir).")
                    }
                }

                Section("Testes") {
                    Button("Enviar notificação de teste") {
                        band.sendNotification(title: "Fit3 Link", body: "Funcionou! A pulseira está conectada ao iPhone.", app: .test)
                    }
                    Button("Simular chamada (8 s)") { simulateCall() }
                    Button("Sincronizar hora e idioma") { band.syncTime() }
                    Button("Atualizar bateria") { band.refreshBattery() }
                }
                .disabled(!band.isReady)

                Section("Notificação personalizada") {
                    TextField("Título", text: $title)
                    TextField("Mensagem", text: $message, axis: .vertical)
                    Button("Enviar para a pulseira") {
                        band.sendNotification(title: title, body: message, app: .other)
                    }
                    .disabled(!band.isReady || title.isEmpty)
                }

                Section {
                    Toggle("Vibrar em chamadas", isOn: $callsEnabled)
                    Toggle("Avisar chamadas perdidas", isOn: $missedEnabled)
                    Toggle("Manter ativo em segundo plano", isOn: Binding(
                        get: { keepAlive },
                        set: { keepAlive = $0; KeepAlive.shared.enabled = $0 }))
                } header: {
                    Text("Chamadas")
                } footer: {
                    Text("O iOS não informa a apps quem está ligando, então a pulseira mostra \"Chamada no iPhone\". Para funcionar com o app fechado, ative \"Manter ativo em segundo plano\" (gasta um pouco mais de bateria) e não feche o app pelo seletor de apps.")
                }

                Section("Mensagens e e-mails") {
                    NavigationLink("Configurar com o app Atalhos") { ShortcutsHelpView() }
                }

                Section("Diagnóstico") {
                    NavigationLink("Log do protocolo") { LogView() }
                    if band.hasBand {
                        Button("Reconectar") { band.reconnect() }
                        Button("Trocar de pulseira") { showScanner = true }
                        Button("Esquecer pulseira", role: .destructive) { band.forget() }
                    }
                }
            }
            .navigationTitle("Fit3 Link")
            .sheet(isPresented: $showScanner) {
                ScannerView().environmentObject(band)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(band.bandName ?? "Galaxy Fit3").font(.headline)
                Text(band.phase.label).font(.subheadline).foregroundStyle(.secondary)
                if let fw = band.firmware {
                    Text("Firmware \(fw)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let battery = band.battery {
                Label(String(battery.percent) + "%", systemImage: battery.charging ? "battery.100.bolt" : "battery.50")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch band.phase {
        case .ready: return .green
        case .bluetoothOff, .unauthorized: return .red
        case .noBand: return .gray
        default: return .orange
        }
    }

    private func simulateCall() {
        let manager = band
        manager.startRinging(name: "Chamada de teste", number: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            manager.callEnded(missed: true, name: "Chamada de teste", number: "")
        }
    }
}

struct ScannerView: View {
    @EnvironmentObject private var band: BandManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(band.discovered) { found in
                        Button {
                            band.choose(found)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(found.name)
                                    Text(String(found.id.uuidString.prefix(8)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(signalText(found.rssi))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if band.discovered.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Procurando…").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Deixe a pulseira perto do iPhone e com a tela ligada. Se o iOS pedir para parear, aceite.")
                }
            }
            .navigationTitle("Escolher pulseira")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear { band.startScan() }
            .onDisappear { band.stopScan() }
        }
    }

    private func signalText(_ rssi: Int) -> String {
        rssi == 0 ? "já conectada" : "\(rssi) dBm"
    }
}

struct LogView: View {
    @EnvironmentObject private var logbook: Logbook

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(logbook.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Log do protocolo")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Limpar") { logbook.clear() }
                ShareLink(item: logbook.text)
            }
        }
    }
}

struct ShortcutsHelpView: View {
    var body: some View {
        List {
            Section {
                Text("O iOS não deixa apps lerem as notificações de outros apps (WhatsApp, Instagram…). Para SMS/iMessage e e-mail, dá para usar automações do app Atalhos, que chamam a ação \"Enviar para a Galaxy Fit3\" deste app.")
            }
            Section("SMS e iMessage") {
                Text("1. Abra Atalhos › Automação › Nova automação › Mensagem.")
                Text("2. Remetente: qualquer um. Marque \"Executar imediatamente\".")
                Text("3. Adicione a ação \"Enviar para a Galaxy Fit3\" (Fit3 Link).")
                Text("4. Título = Remetente, Mensagem = Mensagem, App = Mensagens.")
            }
            Section("E-mail") {
                Text("Mesmo processo com o gatilho \"E-mail\" e App = E-mail. Para Gmail, encaminhe para uma conta no app Mail do iPhone.")
            }
            Section("Chamadas") {
                Text("Chamadas não precisam de atalho: o app detecta sozinho (com o app aberto ou com \"Manter ativo em segundo plano\" ligado).")
            }
        }
        .navigationTitle("Atalhos")
    }
}
