# Curfs TV

Versione minimale di Curfs per le TV Hisense con **VIDAA OS**, usata col telecomando: libreria,
serie con scelta di stagione ed episodio, film che partono con OK, rimozione dalla libreria e
catalogo completo del server. Riprende da dove eri rimasto e propone l'episodio successivo.

Su VIDAA le app sono **web app** (HTML/CSS/JavaScript nel browser della TV, Chromium 111 sul
modello provato). Questa non usa framework né build: i file in `app/` sono già quelli serviti.

## Come funziona

- **L'app sta sul server**, non sulla TV: la TV ha solo un riquadro nel launcher che apre
  l'indirizzo del server. Aggiornare l'app = ricopiare `app/` (`deploy.sh`).
- **Stesso server di Curfs** (nginx con elenchi JSON e richieste Range), con un ingresso in più
  solo per la rete di casa e senza password: vedi `server/nginx-curfs-tv.conf`. L'app legge il
  catalogo da `/media/` e lo ricostruisce con le stesse regole di Curfs (`app/js/catalog.js`).
- **Profili** (obbligatori): all'avvio "Chi guarda?" con i profili creati da Curfs su iPhone o Mac
  (nome e foto); la TV non li crea né li modifica, scrive solo libreria e minutaggio
  (`.curfs/profiles/<id>/library.json` e `progress.json`), condivisi con gli altri dispositivi. Si cambia profilo
  dal tasto in alto. Senza profili sul server, la TV chiede di crearne uno dal telefono.
  Libreria e minutaggio salvati sulla TV prima dei profili si cancellano alla prima scelta.
- Copia locale (localStorage) di libreria e minutaggio per aprire subito. Niente download: una
  web app non può salvare video sulla TV, e in casa lo streaming dal server è equivalente.
- **Locandine**: copertine accanto ai video sul server (`poster.jpg`, `<film>-poster.jpg`, come
  Curfs), altrimenti Wikipedia → IMDb (tramite il proxy `/imdb/` di nginx, facoltativo) → iTunes.
- **Lingua**: quella della TV (italiano, inglese, spagnolo, francese, tedesco; le altre in
  inglese), come Curfs su iPhone e Mac. Testi in `app/js/i18n.js`, con il testo italiano come chiave.
- **Niente sottotitoli** per ora.

## Telecomando

Frecce per muoversi, OK per scegliere, Indietro per tornare (dalla Libreria chiude l'app). Giù
da Libreria/Cerca (o da una stagione) la apre e scende nel contenuto; su dal contenuto torna
sulla scheda aperta.
Nel player: OK pausa/play, ← → ±10 secondi (i salti ravvicinati si sommano), ↓ mostra la barra,
↑ la lingua audio (tracce dentro il file; se il browser della TV non lo permette, lo dice).

## Installazione

1. **Server**: copia `server/nginx-curfs-tv.conf` tra i siti di nginx sostituendo `LAN_IP`,
   `LAN_SUBNET`, `APP_ROOT`, `MEDIA_ROOT`; apri la porta 8092 solo per la rete locale. Per i
   profili, nel sito con la password usato da iPhone/Mac aggiungi il blocco di
   `server/nginx-curfs-profiles.conf` dentro `location /`.
2. **App**: `CURFS_TV_TARGET=utente@server:/percorso/curfs-tv ./deploy.sh`.
3. **Riquadro sulla TV**: VIDAA non permette di installare app proprie dal menu. Si può fare con
   [Sidee](https://github.com/gridoe/Sidee), che usa il canale di rete dell'app ufficiale Hisense
   per il telefono (abbinamento con un PIN mostrato sulla TV) e registra un riquadro con nome,
   indirizzo e icona: `client.pair(...)` e poi `client.add_tile(sessione, "curfstv", "Curfs",
   "http://<server>:8092/", "http://<server>:8092/icon.png")`. Il riquadro resta anche dopo i
   riavvii. Provato su VIDAA 9 (firmware V0010.09.09A.P0930).

## Video che partono subito

Gli mp4 con l'indice (`moov`) in fondo costringono il player a leggere la fine del file prima di
partire: sulla TV in Wi-Fi erano ~7 secondi. `server/faststart.sh CARTELLA` lo sposta all'inizio
senza ricodificare (ffmpeg `-c copy`), un file alla volta, verificando durata e tracce prima di
sostituire l'originale. Si può mettere in un cron per i video nuovi.
