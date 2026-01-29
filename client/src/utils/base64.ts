const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8");

const CHUNK_SIZE = 0x8000;

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
    const chunk = bytes.subarray(i, i + CHUNK_SIZE);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export function base64EncodeUtf8(text: string): string {
  return bytesToBase64(textEncoder.encode(text));
}

export function base64DecodeUtf8(base64: string): string {
  return textDecoder.decode(base64ToBytes(base64));
}
