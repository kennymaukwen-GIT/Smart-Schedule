// WebCrypto calls with the precise result types (the Workers typings return unions for generateKey/exportKey).

export async function generateEcKeyPair(namedCurve: "P-256" | "P-384"): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"])) as CryptoKeyPair;
}

export async function exportKeyBytes(format: "raw" | "pkcs8" | "spki", key: CryptoKey): Promise<Uint8Array> {
  return new Uint8Array((await crypto.subtle.exportKey(format, key)) as ArrayBuffer);
}
