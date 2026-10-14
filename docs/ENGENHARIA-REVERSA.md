# Engenharia reversa: como foi feita e como continuar

Objetivo: interoperabilidade — usar a **sua** Galaxy Fit3 com um iPhone, já que a Samsung só oferece o
app Galaxy Wearable para Android. Nada aqui contorna proteções nem redistribui código da Samsung:
os APKs e o código descompilado ficam só na sua máquina (o `.gitignore` bloqueia `*.apk` e `re/`).

## 1. Ponto de partida: trabalho público

- [yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App) — app Android alternativo (GPL-3.0).
  Recuperou o transporte SAP do firmware AZA3; os testes dele têm pacotes reais capturados.
- [GokulArumugam/Fit3Bridge](https://github.com/GokulArumugam/Fit3Bridge) — porta para iPhone (GPL-3.0);
  conexão, notificações e chamadas testadas numa pulseira real via navegador Bluefy.

Este projeto é uma implementação própria, guiada por esses dois e conferida contra o código da Samsung.

## 2. Verificação independente nos APKs oficiais

Ferramentas: [jadx](https://github.com/skylot/jadx) 1.5.6 + JRE 21 (o Java 8 instalado não roda o jadx).

```powershell
# Baixe os APKs (APKMirror/APKPure) para uma pasta só deles, ex.: re\apk\
#   com.samsung.wearable.fit3plugin   (Galaxy Fit3 Plugin, testado: 2.2.14.26071041N)
#   com.samsung.accessory             (Samsung Accessory Service)
jadx --no-res -d re\fit3plugin re\apk\fit3plugin.apk
jadx --no-res -d re\sas        re\apk\sas.apk
```

O que procurar e onde estava:

| Fato | Classe (código descompilado) |
|---|---|
| UUIDs GATT `1a1a` / `797ae4e9` / `63e30bad` | `com.samsung.accessory.connectivity.ble.SABleConstants` (SAS) |
| Tabela CRC-16/ARC | `com.samsung.accessory.utils.SAFrameworkUtils.CHECKSUM_TABLE` (SAS) |
| IDs de agente (1 OOBE, 3 CALL, 7 NOTIFICATION, 11 SETTINGS…) | `…hostmanager.sharedlib.connection.ConnectionConstants` (plugin) |
| Formato `SAMessageData` (cabeçalho, params LE, strings) | `…hostmanager.message.SAMessageData` (plugin) |
| Pacotes de chamada | `…providers.sacall.message.CallPacketConstructor` (plugin) |
| IDs de idioma (pt_BR = 82) | `…hostmanager.utils.LocaleUtils` (plugin) |
| Mensagens de música (agente 9) | `…providers.samusic.message.SMediaMessageContracts` (plugin) |
| Sessão de saúde (agente 10) | `…providers.sahealthdataprovider` (plugin): `HealthDataManager`, `capabilityexchange`, `largedata`, `healthdataparsers` |
| RFCOMM para arquivos `db764ac8-…` | `p119l7/d.java` (plugin, ofuscado) |

Comandos úteis:

```bash
grep -rn -i "797ae4e9\|63e30bad\|00001a1a" re/sas/sources
grep -rn "AGENT_ID" re/fit3plugin/sources
```

## 3. Testar e explorar com a pulseira pelo PC (Windows)

`tools/fit3ctl.py` fala o protocolo direto do Bluetooth do PC — é o jeito mais rápido de validar tudo
antes de instalar no iPhone, e de descobrir mensagens novas.

```powershell
cd tools
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt

.venv\Scripts\python fit3ctl.py scan                         # acha a pulseira
.venv\Scripts\python fit3ctl.py gatt  <ENDEREÇO>             # lista serviços/características
.venv\Scripts\python fit3ctl.py info  <ENDEREÇO>             # handshake + firmware + bateria
.venv\Scripts\python fit3ctl.py notify <ENDEREÇO> --title "Oi" --body "Teste"
.venv\Scripts\python fit3ctl.py call  <ENDEREÇO> --name "Maria" --number "11999990000"
.venv\Scripts\python fit3ctl.py music <ENDEREÇO>                  # simula um player (tela de música)
.venv\Scripts\python fit3ctl.py health <ENDEREÇO>                 # baixa passos, FC, sono, SpO2
.venv\Scripts\python fit3ctl.py weather <ENDEREÇO> --city Campinas # envia o clima
.venv\Scripts\python fit3ctl.py sniff <ENDEREÇO> --seconds 120 --log captura.txt
.venv\Scripts\python fit3ctl.py raw   <ENDEREÇO> 11 02       # envia SAMessage crua ao serviço 11
```

Antes: a pulseira não pode estar conectada a outro celular (desligue o Bluetooth do Android ou
redefina a pulseira). Se o Windows exigir pareamento, use `--pair`.

## 4. Capturar o tráfego do app oficial (para recursos novos)

Para descobrir algo que ninguém mapeou ainda (ex.: saúde, clima), compare com o app oficial:

1. Num Android com o Galaxy Wearable: Opções do desenvolvedor › **Ativar registro de rastreamento
   HCI Bluetooth**.
2. Use o recurso no app oficial (ex.: sincronizar passos).
3. Gere um relatório de bug (`adb bugreport`) e extraia `btsnoop_hci.log`.
4. Abra no Wireshark, filtre `btatt.handle` da característica notify/write e copie os valores.
5. Decodifique com `tools/fit3/sap.py` (`decode_frame` + `Reassembler`) e procure a classe
   correspondente no plugin descompilado (`providers/<recurso>`).

As capturas podem conter dados pessoais — não publique `btsnoop_hci.log`.

## 5. Limites conhecidos do iOS

- Apps não podem ler notificações de outros apps (WhatsApp etc.). O caminho do sistema seria o ANCS,
  que o firmware da Fit3 não implementa.
- Apps não podem abrir Bluetooth Classic (RFCOMM) sem MFi → instalar mostradores novos/firmware não dá.
- O iOS não informa ao app quem está ligando (só que há uma chamada).
