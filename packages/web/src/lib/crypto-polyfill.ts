// Must be imported before anything else in main.tsx.
//
// crypto.randomUUID() is gated on a secure context, so it is missing whenever
// the app is served over plain http:// on anything but localhost - e.g. a
// phone or laptop hitting http://192.168.x.x:8080 for the phone-camera
// scanner. Our own call sites go through @magic-vault/shared's randomUUID(),
// but third-party code in the bundle calls the global directly, so patch the
// global too.
//
// Installs uuidFromRandomBytes, not randomUUID - the latter delegates to
// crypto.randomUUID when it exists, which after this patch would be itself.
import { uuidFromRandomBytes } from "@magic-vault/shared";

if (typeof globalThis.crypto?.randomUUID !== "function") {
  const descriptor: PropertyDescriptor = {
    value: uuidFromRandomBytes,
    configurable: true,
    writable: true,
  };

  try {
    Object.defineProperty(globalThis.crypto ?? {}, "randomUUID", descriptor);
  } catch {
    // Some engines expose a frozen Crypto instance; patch the prototype.
    Object.defineProperty(Crypto.prototype, "randomUUID", descriptor);
  }
}

export {};
