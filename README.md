# Fit3 Link — Samsung Galaxy Fit3 no iPhone

App iOS não oficial para usar a **Samsung Galaxy Fit3 (SM-R390)** com iPhone. A Samsung só oferece o
Galaxy Wearable para Android; este projeto fala o protocolo da pulseira diretamente, obtido por
engenharia reversa (Samsung SAP sobre Bluetooth LE, serviço GATT `0x1A1A`, sem criptografia).

Não é afiliado à Samsung.

## O que funciona

| Recurso | Estado |
|---|---|
| Conectar, handshake, configuração inicial da pulseira | implementado |
| Hora, fuso e idioma (pt-BR) sincronizados a cada conexão | implementado |
| Bateria | implementado |
| Notificações (teste, personalizada, via Atalhos para SMS/iMessage/e-mail) | implementado |
| Chamadas: pulseira toca com a tela de chamada; chamada perdida | implementado (sem nome de quem liga: limite do iOS) |
| Música: ver a faixa e tocar/pausar, próxima e anterior pela pulseira | implementado (só Apple Music; sem capa; volume experimental) |
| Reconexão automática e restauração em segundo plano | implementado |
| Saúde: passos, distância, calorias, batimentos, oxigênio, estresse e sono no app | implementado (histórico de 30 dias) |
| Envio ao Apple Saúde | implementado no `Fit3Link-Saude.ipa` — depende de o Sideloadly liberar o HealthKit com o seu Apple ID |
| Clima na pulseira (Open-Meteo, pela localização ou cidade) | implementado |
| Notificações do WhatsApp e outros apps | impossível no iOS (sem API; a pulseira não suporta ANCS) |
| Instalar mostradores novos / firmware | impossível no iOS (exige Bluetooth Classic) |

**Status de validação:** o protocolo em Python passa em 44 testes com vetores reais capturados por
terceiros e num teste de ponta a ponta contra uma pulseira emulada; as constantes centrais foram
conferidas no código descompilado dos APKs oficiais. A versão Swift tem a mesma suíte de testes, que
roda no CI do GitHub (macOS). Falta testar **com uma pulseira real** — use o `tools/fit3ctl.py` pelo
PC primeiro.

## Estrutura

```
tools/                 Python (Windows/PC): protocolo + CLI para testar a pulseira via Bluetooth do PC
  fit3/sap.py            transporte SAP: quadros, CRC-16/ARC, fragmentação, handshake
  fit3/messages.py       SAMessageData: OOBE, bateria, notificações, chamadas, música, idiomas
  fit3/health.py         saúde: sessão "Samsung Health", passos, FC, SpO2, sono
  fit3/weather.py        clima: pacote da pulseira + Open-Meteo
  fit3ctl.py             scan · gatt · info · notify · call · music · health · weather · sniff · raw
  tests/                 vetores reais
ios/
  Fit3Kit/               pacote Swift só com o protocolo (testável sem iPhone)
  App/                   app SwiftUI: CoreBluetooth, chamadas (CallKit), Atalhos (App Intents)
  project.yml            XcodeGen
.github/workflows/     CI: testes + compila o .ipa num Mac do GitHub
docs/                  PROTOCOLO.md · ENGENHARIA-REVERSA.md · INSTALACAO.md
```

## Começo rápido

**Testar a pulseira pelo PC (Windows):**

```powershell
cd tools
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python -m unittest discover -s tests -t .
.venv\Scripts\python fit3ctl.py scan
.venv\Scripts\python fit3ctl.py info <ENDEREÇO>
.venv\Scripts\python fit3ctl.py notify <ENDEREÇO> --title "Oi" --body "Do PC"
```

**Instalar no iPhone:** veja [docs/INSTALACAO.md](docs/INSTALACAO.md) (GitHub Actions + Sideloadly,
sem precisar de Mac).

## Créditos e licença

Protocolo baseado no trabalho de [yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App) e
[GokulArumugam/Fit3Bridge](https://github.com/GokulArumugam/Fit3Bridge), ambos GPL-3.0, e conferido
nos APKs oficiais da Samsung (detalhes em [docs/ENGENHARIA-REVERSA.md](docs/ENGENHARIA-REVERSA.md)).
Por isso este projeto também é **GPL-3.0** ([LICENSE](LICENSE)).

Nenhum código ou recurso da Samsung é distribuído aqui.
