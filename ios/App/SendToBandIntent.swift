import AppIntents
import Fit3Kit

/// Ação do app Atalhos: "Enviar para a Galaxy Fit3".
/// Use em automações (Mensagem recebida, E-mail recebido…) para levar avisos à pulseira.
struct SendToBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Enviar para a Galaxy Fit3"
    static var description = IntentDescription("Mostra uma notificação na pulseira Galaxy Fit3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Título")
    var headline: String

    @Parameter(title: "Mensagem", default: "")
    var message: String

    @Parameter(title: "App", default: .messages)
    var app: IntentApp

    static var parameterSummary: some ParameterSummary {
        Summary("Enviar \(\.$headline) para a pulseira") {
            \.$message
            \.$app
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let band = BandManager.shared
        // Aberto em segundo plano pelo Atalhos: dá tempo de reconectar antes de enviar.
        _ = await band.waitUntilReady(timeout: 12)
        band.sendNotification(title: headline, body: message, app: app.forwarded)
        return .result()
    }
}

enum IntentApp: String, AppEnum {
    case messages, mail, phone, other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static var caseDisplayRepresentations: [IntentApp: DisplayRepresentation] = [
        .messages: "Mensagens",
        .mail: "E-mail",
        .phone: "Telefone",
        .other: "Outro",
    ]

    var forwarded: ForwardedApp {
        switch self {
        case .messages: return .messages
        case .mail: return .mail
        case .phone: return .phone
        case .other: return .other
        }
    }
}
