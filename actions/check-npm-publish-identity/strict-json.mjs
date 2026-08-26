// JSON.parse silently keeps the final duplicate object key. Package metadata is
// security input here, so decode it structurally and reject that ambiguity.

export class StrictJsonError extends Error {
  constructor(code, message) {
    super(`${code}: ${message}`);
    this.code = code;
  }
}
function syntaxError(position) {
  return new StrictJsonError('JSON_PARSE_ERROR', `invalid JSON at byte ${position}`);
}

export function parseStrictJson(source) {
  if (typeof source !== 'string') source = Buffer.from(source).toString('utf8');
  let index = 0;

  function whitespace() {
    while (/[\u0009\u000a\u000d\u0020]/.test(source[index] || '')) index += 1;
  }

  function string() {
    const start = index;
    if (source[index] !== '"') throw syntaxError(index);
    index += 1;
    while (index < source.length) {
      const character = source[index];
      if (character === '"') {
        index += 1;
        try {
          return JSON.parse(source.slice(start, index));
        } catch {
          throw syntaxError(start);
        }
      }
      if (character === '\\') {
        const escaped = source[index + 1];
        if (!'"\\/bfnrtu'.includes(escaped || '')) throw syntaxError(index);
        if (escaped === 'u') {
          const hex = source.slice(index + 2, index + 6);
          if (!/^[0-9a-f]{4}$/i.test(hex)) throw syntaxError(index);
          index += 6;
        } else {
          index += 2;
        }
        continue;
      }
      if (character < '\u0020') throw syntaxError(index);
      index += 1;
    }
    throw syntaxError(start);
  }

  function literal(word, value) {
    if (!source.startsWith(word, index)) throw syntaxError(index);
    index += word.length;
    return value;
  }

  function number() {
    const match = source.slice(index).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!match) throw syntaxError(index);
    index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) throw syntaxError(index);
    return value;
  }

  function array() {
    index += 1;
    whitespace();
    const result = [];
    if (source[index] === ']') {
      index += 1;
      return result;
    }
    while (true) {
      result.push(value());
      whitespace();
      if (source[index] === ']') {
        index += 1;
        return result;
      }
      if (source[index] !== ',') throw syntaxError(index);
      index += 1;
      whitespace();
    }
  }

  function object() {
    index += 1;
    whitespace();
    const result = Object.create(null);
    if (source[index] === '}') {
      index += 1;
      return result;
    }
    while (true) {
      const key = string();
      whitespace();
      if (source[index] !== ':') throw syntaxError(index);
      index += 1;
      const entry = value();
      if (Object.hasOwn(result, key)) {
        throw new StrictJsonError('JSON_DUPLICATE_KEY', 'duplicate JSON object key');
      }
      result[key] = entry;
      whitespace();
      if (source[index] === '}') {
        index += 1;
        return result;
      }
      if (source[index] !== ',') throw syntaxError(index);
      index += 1;
      whitespace();
    }
  }

  function value() {
    whitespace();
    switch (source[index]) {
      case '"': return string();
      case '{': return object();
      case '[': return array();
      case 't': return literal('true', true);
      case 'f': return literal('false', false);
      case 'n': return literal('null', null);
      default: return number();
    }
  }

  const result = value();
  whitespace();
  if (index !== source.length) throw syntaxError(index);
  return result;
}
