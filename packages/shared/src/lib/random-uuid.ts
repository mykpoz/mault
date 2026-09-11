// crypto.randomUUID() only exists in a secure context, so it is undefined
// whenever the app is opened over plain http:// on anything but localhost -
// e.g. a phone hitting http://<lan-ip>:8080 for the phone-camera scanner.
// getRandomValues has no such restriction, so fall back to it there.

// Never consults crypto.randomUUID, so it stays safe to install *as*
// crypto.randomUUID (see web's lib/crypto-polyfill.ts) - going through
// randomUUID() below would make such a patched global call itself forever.
export function uuidFromRandomBytes(): string {
  const bytes = new Uint8Array(16);
  const c = globalThis.crypto;

  if (typeof c?.getRandomValues === "function") {
    c.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }

  // RFC 4122 version 4 / variant 10xx bits.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

export function randomUUID(): string {
  const c = globalThis.crypto;

  return typeof c?.randomUUID === "function"
    ? c.randomUUID()
    : uuidFromRandomBytes();
}
