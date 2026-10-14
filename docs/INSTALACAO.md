# Instalar o Fit3 Link no iPhone (sem Mac)

O app não está na App Store. O caminho sem Mac é: **GitHub compila o `.ipa`** num Mac na nuvem →
**você instala** com o seu Apple ID grátis.

## 1. Compilar o `.ipa` no GitHub (uma vez por versão)

1. Crie um repositório no GitHub e envie este projeto (branch `main`).
   Repositório **público** = minutos de macOS grátis; privado consome a cota da conta.
2. O workflow `.github/workflows/build.yml` roda sozinho a cada push: testa o protocolo (Python e
   Swift), compila o app e publica o `Fit3Link.ipa` no release **latest**
   (`https://github.com/<você>/<repo>/releases/tag/latest`).

### Qual `.ipa` baixar?

| Arquivo | Para quê |
|---|---|
| `Fit3Link-Saude.ipa` | **Tente este primeiro.** Igual ao outro, mais o envio de passos, batimentos, sono e oxigênio ao **Apple Saúde**. |
| `Fit3Link.ipa` | Use se o Sideloadly der erro com o de cima (por exemplo, recusar o HealthKit com Apple ID grátis). Os dados de saúde continuam aparecendo dentro do app; só não vão para o Apple Saúde. |

Não se sabe ao certo se o Apple ID grátis libera o HealthKit em apps instalados pelo Sideloadly; as
fontes divergem. Por isso existem os dois. Se o `Fit3Link-Saude.ipa` instalar, ative **Enviar ao
Apple Saúde** no app: o iPhone vai pedir a permissão. Se aparecer um erro de *entitlement*, é a
assinatura grátis recusando o HealthKit, e o resto do app funciona normalmente.

## 2a. Instalar pelo Windows com Sideloadly (recomendado para você)

1. Instale o [Sideloadly](https://sideloadly.io) e o **iTunes + iCloud baixados do site da Apple**
   (não a versão da Microsoft Store), como o Sideloadly pede.
2. Conecte o iPhone por USB e toque em **Confiar** no iPhone.
3. Arraste o `Fit3Link.ipa` para o Sideloadly, informe seu Apple ID e clique em **Start**.
4. No iPhone:
   - Ajustes › Privacidade e Segurança › **Modo de Desenvolvedor** › ativar (o iPhone reinicia).
   - Ajustes › Geral › **VPN e Gerenciamento de Dispositivos** › confiar no seu Apple ID.

Com Apple ID grátis o app **expira a cada 7 dias**: reinstale pelo Sideloadly (ele tem renovação
automática via Wi-Fi com o PC ligado). Limite: 3 apps instalados assim por vez.

## 2b. Alternativa: SideStore

O [SideStore](https://docs.sidestore.io) renova o app no próprio iPhone, sem PC (precisa de um
computador só na configuração inicial). Depois: **Meus Apps › +** e escolha o `Fit3Link.ipa`.

## 2c. Se você tiver acesso a um Mac

```bash
brew install xcodegen
cd ios && xcodegen generate && open Fit3Link.xcodeproj
```

Em *Signing & Capabilities* escolha seu Personal Team e rode no iPhone.

## 3. Primeira conexão

1. Se a pulseira estava num Android: desligue o Bluetooth dele **ou** redefina a pulseira
   (na pulseira: Configurações › Geral › Redefinir).
2. Abra o Fit3 Link › **Procurar minha Galaxy Fit3** › toque na pulseira. Aceite o pareamento se o iOS pedir.
3. O status deve ir de *Handshake…* → *Configurando…* → **Conectada**.
4. Toque em **Enviar notificação de teste** e **Simular chamada**.
5. Algo deu errado? Diagnóstico › **Log do protocolo** › compartilhar, e analise/envie o log.

## 4. SMS, iMessage e e-mail

Veja no app: Mensagens e e-mails › **Configurar com o app Atalhos**. Resumo: Atalhos › Automação ›
gatilho *Mensagem* › “Executar imediatamente” › ação **Enviar para a Galaxy Fit3**.
