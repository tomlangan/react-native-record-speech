"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.arrayBufferToBase64 = arrayBufferToBase64;
exports.base64ToArrayBuffer = base64ToArrayBuffer;
exports.calculateBase64ByteLength = calculateBase64ByteLength;
exports.concatenateBase64BlobsToArrayBuffer = concatenateBase64BlobsToArrayBuffer;
var _buffer = require("buffer");
function base64ToArrayBuffer(base64) {
  return _buffer.Buffer.from(base64, "base64");
}
function arrayBufferToBase64(arrayBuffer) {
  const buffer = _buffer.Buffer.from(arrayBuffer);
  return buffer.toString("base64");
}
async function concatenateBase64BlobsToArrayBuffer(blobs) {
  // Convert each base64 blob to an ArrayBuffer
  const arrayBuffers = blobs.map(blob => base64ToArrayBuffer(blob));

  // Calculate the total size
  let totalSize = 0;
  arrayBuffers.forEach(ab => {
    totalSize += ab.byteLength;
  });

  // Create a new ArrayBuffer of total size
  const concatenated = new Uint8Array(totalSize);

  // Copy each original ArrayBuffer into the new one
  let offset = 0;
  arrayBuffers.forEach(ab => {
    concatenated.set(new Uint8Array(ab), offset);
    offset += ab.byteLength;
  });

  // Return the concatenated ArrayBuffer
  return concatenated.buffer;
}
function calculateBase64ByteLength(base64String) {
  // Remove padding
  var padding = 0;
  if (base64String.endsWith("==")) padding = 2;else if (base64String.endsWith("=")) padding = 1;

  // Calculate byte length
  var byteLength = base64String.length * 6 / 8 - padding;
  return byteLength;
}
//# sourceMappingURL=bufferutils.js.map