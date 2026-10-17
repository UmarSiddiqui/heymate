// JavaScriptCore has ECMAScript built-ins but no browser TextEncoder.
// WHATWG UTF-8 encoding, including replacement for unpaired surrogates.
globalThis.TextEncoder = class {
  encode(input = "") {
    const bytes = [];
    for (const character of String(input)) {
      let scalar = character.codePointAt(0);
      if (scalar >= 0xd800 && scalar <= 0xdfff) scalar = 0xfffd;
      if (scalar < 0x80) bytes.push(scalar);
      else if (scalar < 0x800) bytes.push(0xc0 | scalar >> 6, 0x80 | scalar & 63);
      else if (scalar < 0x10000) bytes.push(0xe0 | scalar >> 12, 0x80 | scalar >> 6 & 63, 0x80 | scalar & 63);
      else bytes.push(0xf0 | scalar >> 18, 0x80 | scalar >> 12 & 63, 0x80 | scalar >> 6 & 63, 0x80 | scalar & 63);
    }
    return new Uint8Array(bytes);
  }
};
