/// Öffentlicher Ed25519-Schlüssel, mit dem Update-Manifeste signiert sind (hex).
///
/// Leer = Updates werden nur über HTTPS und SHA-256 geprüft (keine Signatur).
/// Einrichten: `mync-core keygen update-key.txt`, den geheimen Schlüssel als
/// GitHub-Secret `MYNC_UPDATE_KEY` hinterlegen und den ausgegebenen
/// öffentlichen Schlüssel hier eintragen (oder beim Bauen per
/// `--dart-define=MYNC_UPDATE_PUBKEY=…` setzen).
const updatePublicKeyInRepo = '';

const updatePublicKey = String.fromEnvironment(
  'MYNC_UPDATE_PUBKEY',
  defaultValue: updatePublicKeyInRepo,
);
