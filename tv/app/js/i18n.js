// Lingua dell'app TV: quella della TV (navigator.language), come Curfs su
// iPhone e Mac: italiano, inglese, spagnolo, francese, tedesco; tutte le
// altre in inglese. Le chiavi sono il testo italiano; {nome} = segnaposto.

const STRINGS = {
  'Il server non risponde. Controlla che la TV sia sulla rete di casa.': [
    'The server isn’t responding. Check that the TV is on your home network.',
    'El servidor no responde. Comprueba que la TV esté en la red de casa.',
    'Le serveur ne répond pas. Vérifiez que la TV est sur le réseau de la maison.',
    'Der Server antwortet nicht. Prüfe, ob der Fernseher im Heimnetz ist.'],
  'Non riesco a leggere i profili dal server.': [
    'Can’t read the profiles from the server.',
    'No se pueden leer los perfiles del servidor.',
    'Impossible de lire les profils sur le serveur.',
    'Die Profile können nicht vom Server gelesen werden.'],
  'Sul server non c’è ancora nessun profilo.': [
    'There are no profiles on the server yet.',
    'Todavía no hay perfiles en el servidor.',
    'Il n’y a encore aucun profil sur le serveur.',
    'Auf dem Server gibt es noch keine Profile.'],
  'Crea il tuo dall’app Curfs su iPhone o Mac (in alto nella Libreria), poi riprova.': [
    'Create yours in the Curfs app on iPhone or Mac (top of the Library), then try again.',
    'Crea el tuyo en la app Curfs de iPhone o Mac (arriba en la Biblioteca) y vuelve a intentarlo.',
    'Créez le vôtre dans l’app Curfs sur iPhone ou Mac (en haut de la Bibliothèque), puis réessayez.',
    'Erstelle deins in der Curfs-App auf iPhone oder Mac (oben in der Mediathek) und versuche es dann erneut.'],
  'Riprova': ['Try Again', 'Reintentar', 'Réessayer', 'Erneut versuchen'],
  'Chi guarda?': ['Who’s watching?', '¿Quién está viendo?', 'Qui regarde ?', 'Wer schaut?'],
  'I profili si creano dall’app Curfs su iPhone o Mac. Riprendi da dove eri rimasto anche lì.': [
    'Profiles are created in the Curfs app on iPhone or Mac. Pick up where you left off there too.',
    'Los perfiles se crean en la app Curfs de iPhone o Mac. Continúa donde lo dejaste también allí.',
    'Les profils se créent dans l’app Curfs sur iPhone ou Mac. Reprenez là où vous vous êtes arrêté, là aussi.',
    'Profile werden in der Curfs-App auf iPhone oder Mac erstellt. Mach auch dort weiter, wo du aufgehört hast.'],
  'Libreria': ['Library', 'Biblioteca', 'Bibliothèque', 'Mediathek'],
  'Cerca': ['Search', 'Buscar', 'Rechercher', 'Suchen'],
  'Fine': ['Done', 'Listo', 'OK', 'Fertig'],
  'Modifica': ['Edit', 'Editar', 'Modifier', 'Bearbeiten'],
  'La libreria è vuota': ['Your library is empty', 'La biblioteca está vacía', 'La bibliothèque est vide', 'Die Mediathek ist leer'],
  'Vai su Cerca e aggiungi film e serie dal tuo server.': [
    'Go to Search and add movies and series from your server.',
    'Ve a Buscar y añade películas y series de tu servidor.',
    'Allez dans Rechercher et ajoutez des films et des séries depuis votre serveur.',
    'Geh zu Suchen und füge Filme und Serien von deinem Server hinzu.'],
  'Premi OK su un titolo per toglierlo dalla libreria.': [
    'Press OK on a title to remove it from the library.',
    'Pulsa OK en un título para quitarlo de la biblioteca.',
    'Appuyez sur OK sur un titre pour le retirer de la bibliothèque.',
    'Drücke OK auf einem Titel, um ihn aus der Mediathek zu entfernen.'],
  'La tua libreria': ['Your Library', 'Tu biblioteca', 'Votre bibliothèque', 'Deine Mediathek'],
  'Da scoprire sul server': ['To discover on the server', 'Por descubrir en el servidor', 'À découvrir sur le serveur', 'Auf dem Server entdecken'],
  'Prossimo episodio': ['Next Episode', 'Siguiente episodio', 'Épisode suivant', 'Nächste Folge'],
  'Continua a guardare': ['Continue Watching', 'Seguir viendo', 'Reprendre', 'Weiterschauen'],
  '▶  OK per riprendere · mancano {n} min': [
    '▶  OK to resume · {n} min left', '▶  OK para continuar · quedan {n} min',
    '▶  OK pour reprendre · encore {n} min', '▶  OK zum Fortsetzen · noch {n} Min.'],
  '▶  OK per guardarlo': ['▶  OK to watch', '▶  OK para verlo', '▶  OK pour regarder', '▶  OK zum Ansehen'],
  'Nessun video sul server': ['No videos on the server', 'No hay vídeos en el servidor', 'Aucune vidéo sur le serveur', 'Keine Videos auf dem Server'],
  'Serie TV': ['TV Shows', 'Series', 'Séries', 'Serien'],
  'Film': ['Movies', 'Películas', 'Films', 'Filme'],
  'Togliere "{t}" dalla libreria?': [
    'Remove “{t}” from the library?', '¿Quitar «{t}» de la biblioteca?',
    'Retirer « {t} » de la bibliothèque ?', '„{t}“ aus der Mediathek entfernen?'],
  'Si toglie dalla libreria del profilo, anche su iPhone e Mac. I video sul server restano.': [
    'It’s removed from the profile’s library, on iPhone and Mac too. The videos stay on the server.',
    'Se quita de la biblioteca del perfil, también en iPhone y Mac. Los vídeos se quedan en el servidor.',
    'Il est retiré de la bibliothèque du profil, aussi sur iPhone et Mac. Les vidéos restent sur le serveur.',
    'Es wird aus der Mediathek des Profils entfernt, auch auf iPhone und Mac. Die Videos bleiben auf dem Server.'],
  'Rimuovi': ['Remove', 'Quitar', 'Retirer', 'Entfernen'],
  'Annulla': ['Cancel', 'Cancelar', 'Annuler', 'Abbrechen'],
  'Guarda {c}': ['Watch {c}', 'Ver {c}', 'Regarder {c}', '{c} ansehen'],
  'Rivedi {c}': ['Rewatch {c}', 'Volver a ver {c}', 'Revoir {c}', '{c} erneut ansehen'],
  'Riprendi {c}': ['Resume {c}', 'Continuar {c}', 'Reprendre {c}', '{c} fortsetzen'],
  '1 stagione': ['1 season', '1 temporada', '1 saison', '1 Staffel'],
  '{n} stagioni': ['{n} seasons', '{n} temporadas', '{n} saisons', '{n} Staffeln'],
  '1 episodio': ['1 episode', '1 episodio', '1 épisode', '1 Folge'],
  '{n} episodi': ['{n} episodes', '{n} episodios', '{n} épisodes', '{n} Folgen'],
  '✓  In libreria': ['✓  In Library', '✓  En la biblioteca', '✓  Dans la bibliothèque', '✓  In der Mediathek'],
  '+  Aggiungi alla libreria': ['+  Add to Library', '+  Añadir a la biblioteca', '+  Ajouter à la bibliothèque', '+  Zur Mediathek hinzufügen'],
  'Stagione {n}': ['Season {n}', 'Temporada {n}', 'Saison {n}', 'Staffel {n}'],
  'Parte tra {n} s · OK per guardarlo ora · Indietro per uscire': [
    'Starts in {n} s · OK to watch now · Back to exit',
    'Empieza en {n} s · OK para verlo ya · Atrás para salir',
    'Commence dans {n} s · OK pour regarder maintenant · Retour pour quitter',
    'Startet in {n} s · OK zum sofortigen Ansehen · Zurück zum Beenden'],
  '↑ Lingua audio': ['↑ Audio language', '↑ Idioma del audio', '↑ Langue audio', '↑ Audiosprache'],
  'Lingua audio': ['Audio Language', 'Idioma del audio', 'Langue audio', 'Audiosprache'],
  'Questa TV non permette di scegliere la lingua audio.': [
    'This TV doesn’t let you choose the audio language.',
    'Esta TV no permite elegir el idioma del audio.',
    'Cette TV ne permet pas de choisir la langue audio.',
    'Dieser Fernseher erlaubt keine Auswahl der Audiosprache.'],
  'Questo video ha una sola lingua audio: {l}.': [
    'This video has only one audio language: {l}.', 'Este vídeo solo tiene un idioma de audio: {l}.',
    'Cette vidéo n’a qu’une seule langue audio : {l}.', 'Dieses Video hat nur eine Audiosprache: {l}.'],
  'OK per scegliere · Indietro per chiudere': [
    'OK to choose · Back to close', 'OK para elegir · Atrás para cerrar',
    'OK pour choisir · Retour pour fermer', 'OK zum Auswählen · Zurück zum Schließen'],
  'Indietro per chiudere': ['Back to close', 'Atrás para cerrar', 'Retour pour fermer', 'Zurück zum Schließen'],
  'Traccia {n}': ['Track {n}', 'Pista {n}', 'Piste {n}', 'Spur {n}'],
  'Questo video non si riesce a riprodurre sulla TV.': [
    'This video can’t be played on the TV.',
    'Este vídeo no se puede reproducir en la TV.',
    'Cette vidéo ne peut pas être lue sur la TV.',
    'Dieses Video kann auf dem Fernseher nicht abgespielt werden.'],
};

const LANGS = ['en', 'es', 'fr', 'de'];
const code = String(navigator.language || 'en').slice(0, 2).toLowerCase();
export const lang = code === 'it' || LANGS.includes(code) ? code : 'en';
document.documentElement.lang = lang;

/** Testo nella lingua della TV; `vars` riempie i segnaposto {nome}. */
export function t(key, vars = {}) {
  const i = LANGS.indexOf(lang);
  const text = (i >= 0 && STRINGS[key]?.[i]) || key;
  return text.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? vars[k] : `{${k}}`));
}

/** Plurali: chiave '1 …' per uno, '{n} …' per gli altri. */
export function plural(n, one, other) {
  return n === 1 ? t(one) : t(other, { n });
}
