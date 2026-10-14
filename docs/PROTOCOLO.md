# Protocolo do Galaxy Fit3 (SM-R390)

Implementado em `tools/fit3/` (Python) e `ios/Fit3Kit/` (Swift), com os mesmos vetores de teste.

Legenda da origem de cada informação:

- ✅ **Verificado** neste projeto, no código descompilado dos APKs oficiais da Samsung
  (veja [ENGENHARIA-REVERSA.md](ENGENHARIA-REVERSA.md)).
- 🧪 **Comunidade**: vindo de [yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App) (GPL-3.0),
  recuperado do firmware AZA3 e testado por terceiros em pulseiras reais. Ainda não testado aqui com
  uma pulseira — o `tools/fit3ctl.py` existe para isso.

## Visão geral

```
iPhone (central BLE)                         Galaxy Fit3 (periférico BLE)
        │  GATT, serviço 0x1A1A                         │
        │── assina notify 797ae4e9 ────────────────────▶│
        │◀──────────── pedido de capacidade (105 bytes) │  handshake (fora de quadro)
        │── mesma coisa com byte[1]=0x15 ──────────────▶│
        │── quadros SAP (write 63e30bad) ──────────────▶│  mensagens SAMessageData
        │◀──────────────── quadros SAP (notify) ────────│  por "agente" (serviço)
```

Não há criptografia na camada de aplicação. O iOS pode mostrar o pedido de pareamento do sistema.

## GATT ✅

Em `com.samsung.accessory.connectivity.ble.SABleConstants` (app *Samsung Accessory Service*):

| | UUID |
|---|---|
| Serviço (`DPS_SERVICE`) | `00001a1a-0000-1000-8000-00805f9b34fb` |
| Notify, pulseira → celular (`DPS_READ_CHAR`) | `797ae4e9-2e58-4fe8-b48d-b5c79599fb9b` |
| Write, celular → pulseira (`DPS_WRITE_CHAR`) | `63e30bad-4206-4596-839f-e47cbf7a4b5d` |

O plugin `com.samsung.wearable.fit3plugin` **não** contém esses UUIDs: ele delega o transporte ao
framework de acessórios. O plugin só usa Bluetooth Classic (RFCOMM `db764ac8-4b08-7f25-aafe-59d03c27bae3`)
para transferir arquivos grandes (mostradores, firmware) — algo que apps iOS não conseguem abrir.

## Handshake 🧪

1. Assinar a característica notify.
2. A pulseira envia 105 bytes: `data[0] = 104`, `data[1] = 0x14`.
   MTU de transporte SAP = `data[0x2c] << 8 | data[0x2d]` (normalmente 500).
3. Responder com os **mesmos 105 bytes**, trocando `data[1]` para `0x15` (sem quadro SAP).

Se o iOS restaurar o app com o link ainda assinado, a pulseira **não** repete o handshake; o app
reaproveita o MTU salvo e, se a pulseira não responder, derruba e refaz a conexão.

## Quadro SAP

```
quadro  = prefixo | corpo | crc16(corpo)          CRC-16/ARC, big-endian ✅
prefixo = [len, len]                              se MTU de transporte < 256 🧪
        = [lenHi, lenLo, crc16(len) BE]           caso contrário
corpo   = [flags, seq, svc, svc, payload…]        único (flags=0, seq=0x40) ou PRIMEIRO (flags=0x02)
        = [flags, seq, payload…]                  CONTINUAÇÃO (0x04) / ÚLTIMO (0x06)
flags bits 1..2 = tipo · seq: nibble baixo = nº do fragmento, bits 5..7 = stream
```

- CRC ✅: tabela `SAFrameworkUtils.CHECKSUM_TABLE` = CRC-16/ARC (poly `0xA001` refletido, init 0;
  valor de verificação de `"123456789"` = `0xBB3D`).
- Vetor real (WatchInfo, MTU 500): `000dc5c10040010101040200000005000e60ea` 🧪
- Remontagem: uma mensagem por vez, ≤ 4096 bytes, ≤ 16 fragmentos.

## Mensagens `SAMessageData` ✅

Em `com.samsung.wearable.hostmanager.message.SAMessageData`:

- Byte 0 = `formato << 7 | tipo << 6 | id` (formato 0 fixo / 1 variável; tipo 0 pedido / 1 resposta).
- Formato variável: byte 1 = número de parâmetros.
- Parâmetro = `id` + valor. Little-endian: byte 1, short 2, int 4, long 8 bytes.
- String = 1 byte de tamanho + bytes (máx. 255). Exceção: corpo de notificação usa 2 bytes de tamanho 🧪.
- Resposta costuma ser `0x40 | id`.

## Agentes (ID de serviço SAP) ✅

`com.samsung.wearable.hostmanager.sharedlib.connection.ConnectionConstants`:

| ID | Agente | Uso |
|---|---|---|
| 1 | OOBE | configuração inicial, hora, fuso, idioma |
| 3 | CALL | tela de chamada, chamadas perdidas |
| 6 | BAND_FACE | mostradores |
| 7 | NOTIFICATION | notificações |
| 11 | FULL_SETTINGS | bateria, idioma, ajustes |
| 12 | DEBUG | |
| 14 | REMINDER | |
| 15 / 19 / 24 | WIDGETS / QS (painel rápido) / APPS | ordem |
| 18 | QUICK_MESSAGE | respostas rápidas |
| 26 | SHARED_INFO | |

Da comunidade 🧪: 4 localização, 5 clima, 8 calendário, 9 mídia, 10 saúde, 30 transferência OTA.

## OOBE / configuração (serviço 1) 🧪 — feita a cada conexão

| Passo | celular → pulseira | resposta |
|---|---|---|
| 1 WatchInfo | `01 04 02 00 00 00 05 00 0e` | `0x41 …` (contém o firmware `R390…`) |
| 2 Estado | `02 01 00` | `0x42 …` |
| 3 Ajustes | `83 01 <idiomaLE16> 02 00 03 <len> <epochASCII> 04 <neg?1:0> <|fuso|LE16> 05 <24h>` | `0x43 …` |
| 4 Termos | `84 01 01` | `0x44 …` |

O passo 3 sozinho sincroniza a hora. Vetor: 2023-11-14 22:13:20Z, UTC+3, idioma 57 →
`830139000200030a313730303030303030300400302a0501`.

IDs de idioma ✅ (`com.samsung.wearable.hostmanager.utils.LocaleUtils`): **pt-BR = 82**, pt-PT = 55,
en = 13, en-US = 100, es-ES = 14…

## Bateria (serviço 11) 🧪

Pedido `02`. Resposta `0x42` com parâmetros `5 = nível (0–100)` e `6 = carregando (0–3)`.
Ex.: `42 05 3a 06 00` = 58 %, sem carregar.

## Notificações (serviço 7) 🧪

- Pedido de capacidade de ícones `0d` (o app Android oficial faz isso antes de notificar).
- Nova notificação (`0x80` = popup; `0x85` = silenciosa):

```
80 <nParams = 10 (+1 se categoria)>
  00 01                    tipo: normal
  01 <seq int32 LE>        sequência (> 0, única)
  06 <len> "<appId>"       id do app em texto (usamos 20..24)
  02 <millis int64 LE>     horário
  03 <len> <título ≤ 60 B>
  04 <lenLE16> <corpo ≤ 100 B>
  0e <len> <nome do app ≤ 60 B>
  0f 01
  10 00
  [0c <len> <categoria>]   msg, email, call…
  12 <len> <pacote Android>
```

- Confirmação da pulseira: `40 01 <seq LE32> 0b <1 = aceita>`.
- Apagar: `01 01 <seq LE32>`; limpar tudo: `08`.

## Chamadas (serviço 3) ✅

`com.samsung.wearable.providers.sacall.message.CallPacketConstructor` / `CallPacketConstants`:

| Mensagem | Bytes |
|---|---|
| Habilitar avisos de chamada (id 8) | `08 01` |
| Contato (id 2, variável, 7 params) | `82 07  00 <1=voz,0=vídeo>  07 <int32 1>  05 <len> "com.samsung.android.providers.sacall.SACallHandlerService"  06 <millis LE64>  04 <len> <nome>  03 <len> <número>  09 <exceção NP 0/1>` |
| Estado (id 3) | `03 01` tocando · `03 02` atendida · `03 00` ociosa |
| Chamada perdida (id 6; id 10 = atualização silenciosa) | `86 03  04 <len> <nome>  03 <len> <número>  06 <millis LE64>` |
| Apagar perdidas | `07` |

Se nome == número, o nome vai vazio (igual ao plugin). Pedidos da pulseira → celular:
1 silenciar, 4 mostrar no celular, 5 recusar, 9 sincronizar perdidas, 13 retornar ligação,
14 recusar com mensagem, 15 limpar perdidas. **O iOS não permite** que apps silenciem ou recusem
chamadas; o app apenas para a vibração da pulseira.

## Música (serviço 9) ✅ IDs / 🧪 fluxo

IDs em `com.samsung.wearable.providers.samusic.message.SMediaMessageContracts`; fluxo e pacotes de
referência (gerados pelo `Builder` original) vindos do Fit3-App.

Pulseira → celular (pedidos):

| ID | Pedido | Formato |
|---|---|---|
| 1 | tela de música mudou | `01 01 <0 fechada · 1 visível · 2 always-on>` |
| 2 / 3 | metadados / estado | `02`, `03` |
| 4 | botão | `04 01 <1 parar · 2 tocar/pausar · 3 anterior · 4 próxima> [02 <1 solto · 2 pressionado>]` |
| 5 / 6 | capacidade / volume | `05`, `06` |
| 7 | mudar volume | `07 01 <1 definir · 2 + · 3 − · 4 mudo · 5 tirar mudo> [02 <valor>]` |
| 8 / 9 | info do app / fila | `08 01 <len> <appId>` |

Um toque no botão gera **dois** pacotes (solto e pressionado): aja só no pressionado.

Celular → pulseira (respostas). As "fixas" do agente 9 levam o número de parâmetros no byte 1:

| ID | Resposta | Bytes |
|---|---|---|
| 17 | metadados | `d1 05  01 <duração ms LE64>  02 <len> <título>  03 <len> <artista>  04 <len> <capa>  05 <len> <appId>` |
| 18 | estado | `d2 04  01 <1 parado · 2 pausado · 3 tocando>  02 <posição ms LE64>  04 <item ativo LE64, -1>  03 <len> <appId>` |
| 20 | capacidade | `54 02  01 <vol. máx LE32>  02 <vol. de aviso LE32>` |
| 21 | volume | `55 02  01 <volume LE32>  02 <1 alto-falante · 2 fone>` |
| 22 | info do app | `d6 03  01 <appId>  02 <nome>  03 <ícone>` |
| 23 | eco da tela | `57 01  01 <estado recebido>` |
| 24 | player ativo | `d8 02  01 <0/1>  02 <len> <appId>` — enviar **antes** dos metadados |
| 25 | fila | `d9 04  01 <appId>  02 <título>  03 <qtd LE32>  04 <arquivo>` (vazia no iOS) |

A capa do álbum e a fila são transferidas como arquivos por Bluetooth Classic → indisponíveis no iOS.

## Saúde (serviço 10) 🧪

Recuperado do plugin oficial (`HealthDataManager`, `ModenConstant`, `ConsolidatedSyncDataParser`)
pelo Fit3-App e testado em pulseiras AZA3. O celular se apresenta como **Samsung Health 7.0.6**.

| Passo | Mensagem |
|---|---|
| 1. Pulseira pede capacidade GM | `A2 02  E0 <seq LE>  E1 <proto LE>` |
| 2. Celular responde | `E2 06  D0 02  D1 00  D2 <7006011 LE32>  D3 <6040000 LE32>  E0 <seq>  E1 <proto>` |
| 3. Celular pede capacidade do host (650 ms depois) | `34` |
| 4. Pulseira pergunta a versão | `A0 …  E0 <seq LE> …` |
| 5. Celular responde | `E0 …` com protocolo 4.51 e 10 strings JSON (> 500 bytes, fragmentado) |
| 6. Celular pede os dados | `03 E0 <seq LE> 05 19 01 00 02 00 00 03 04 33  04 <0>  05 <0>  06 <agora desde 1990, LE32>  07 01` (31 bytes) |
| 7. Pulseira envia lotes | `82 03 E0 <seq LE> <tipo> …` |
| 8. Celular confirma **cada lote** | `42 02 E0 <seq do lote> 04 02 01 01` |

Outros: a pulseira pede dados ao celular (`03 E0 <seq>…`) → `43 E0 <seq> 04 02 01 01`;
`01` → `41`; `04` → `44`. Lotes grandes vêm em blocos `3F <flag 0 primeiro · 1 meio · 2 último> <nº LE32> <dados>`
e cada lote completo é confirmado com `3E 09 <qtd LE32>` (ou `3E 08` para recusar). **Sem a
confirmação certa, a pulseira reenvia os mesmos dados.** Os tempos são segundos desde 1990-01-01 UTC.

IDs de campo em hexadecimal:

| Tipo | Conteúdo | Formato do registro |
|---|---|---|
| 7 | passos (intervalos de 1 min) | `<tem mais> 05 1 2 3 10(passos) 11(distância m, float) 12 13(kcal, float) 14(corrida) 15(caminhada) 16(duração ms) 17(1 byte)` — 4 bytes cada |
| 10 | frequência cardíaca | `<tem mais> <tamanho LE32> 01 início 02 fim 20 valor 21 mín 22 máx …` |
| 16 | sono (episódio) | idem, `53` nota, `75` UUID de 16 bytes |
| 17 | estágios do sono | 8 campos fixos, `52` estágio (40001 acordado · 40002 leve · 40003 profundo · 40004 REM), `55` UUID do episódio |
| 19 | estresse | `60` valor, `66`/`67` mín/máx |
| 112 | SpO2 | `A9` valor, `AB`/`AC` mín/máx |

Campos desconhecidos fazem o registro inteiro ser rejeitado: nada é "adivinhado" dos bytes.

## Clima (serviço 5) 🧪

Pulseira pede com `00` (abriu o clima) ou `01 00 01` (atualizar). Resposta `C1 <nParams 16 bits BE> …`
no formato de `SAWeatherMessageData.buildMSGData(WEATHER_INFO)`. Atenção às ordens de bytes (confirmadas
em pulseira real): **medidas de 16 bits em little-endian** e **horários de 32 bits em big-endian**.

| ID | Campo |
|---|---|
| 8, 6, 9, 10, 7, 11, 12, 18 | fixos: índices TWC, Celsius, sem aviso de local, local ativo, 1 cidade, cidade atual |
| 13 / 14 / 15 / 28 | cidade, estado, país, fuso (texto) |
| 16 / 17 | ícone atual, é dia |
| 19 | atualizado em (BE32) |
| 20–25 | temperatura, máx., mín., sensação, máx./mín. de ontem (LE16, °C) |
| 26 / 27 | nascer / pôr do sol (BE32) |
| 29, depois 30–35 × N | horas (até 24): índice, é dia, hora, ícone, temperatura, % de chuva |
| 36, depois 37–43 × N | dias (até 6): índice, data, ícones, máx., mín. |
| 44–49 | qualidade do ar (zeros) |
| 50–54 | UV, texto do UV, vento km/h, texto do vento, umidade |

Ícones: código WMO do Open-Meteo convertido para o índice da Samsung (`samsung_icon`). Pacote ≤ 980 bytes.

## Ainda não implementado

- **Ícones de apps** nas notificações (pedido `APP_ICON_<id>` da pulseira, envio fragmentado).
- **Metas de atividade**, ajustes completos, trocar mostrador (serviço 6; instalar novos exige
  RFCOMM, impossível no iOS sem MFi).
