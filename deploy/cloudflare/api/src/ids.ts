// Random identifiers, shared by the WebP service, the studio and the library.

const BASE62 =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

// Uniform base62 from random bytes: bytes >= 248 (= 62 * 4) are discarded so
// there is no modulo bias.
export function randomBase62(
    length: number,
    randomBytes: (n: number) => Uint8Array = (n) =>
        crypto.getRandomValues(new Uint8Array(n)),
): string {
    let out = "";
    while (out.length < length) {
        for (const b of randomBytes(length * 2)) {
            if (b < 248 && out.length < length) out += BASE62[b % 62];
        }
    }
    return out;
}
