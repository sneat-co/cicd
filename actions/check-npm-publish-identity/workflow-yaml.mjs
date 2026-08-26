// A deliberately small, structural YAML decoder for GitHub workflow/action
// files. It accepts the YAML forms we audit and rejects everything else. That
// is safer than guessing from text: unsupported syntax is audit evidence, not
// an implicit "unarmed" verdict.

function parseError(line, message) {
  throw new Error(`YAML_PARSE_ERROR line ${line}: ${message}`);
}

function clone(value) {
  if (Array.isArray(value)) return value.map(clone);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, clone(entry)]));
  return value;
}

function stripComment(line) {
  let quote;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (quote === "'") {
      if (character === "'" && line[index + 1] === "'") index += 1;
      else if (character === "'") quote = undefined;
      continue;
    }
    if (quote === '"') {
      if (character === '\\') index += 1;
      else if (character === '"') quote = undefined;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === '#' && (index === 0 || /\s/.test(line[index - 1]))) return line.slice(0, index).trimEnd();
  }
  return line.trimEnd();
}

function splitMapping(text, line) {
  let quote;
  let depth = 0;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quote === "'") {
      if (character === "'" && text[index + 1] === "'") index += 1;
      else if (character === "'") quote = undefined;
      continue;
    }
    if (quote === '"') {
      if (character === '\\') index += 1;
      else if (character === '"') quote = undefined;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (character === '[' || character === '{' || character === '(') depth += 1;
    else if (character === ']' || character === '}' || character === ')') depth -= 1;
    else if (character === ':' && depth === 0 && (index + 1 === text.length || /\s/.test(text[index + 1]))) {
      return [text.slice(0, index).trim(), text.slice(index + 1).trim()];
    }
  }
  parseError(line, 'expected a mapping key');
}

function splitFlow(text, line) {
  const result = [];
  let start = 0;
  let quote;
  let depth = 0;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quote === "'") {
      if (character === "'" && text[index + 1] === "'") index += 1;
      else if (character === "'") quote = undefined;
      continue;
    }
    if (quote === '"') {
      if (character === '\\') index += 1;
      else if (character === '"') quote = undefined;
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (character === '[' || character === '{') depth += 1;
    else if (character === ']' || character === '}') depth -= 1;
    else if (character === ',' && depth === 0) {
      result.push(text.slice(start, index).trim());
      start = index + 1;
    }
  }
  if (quote || depth !== 0) parseError(line, 'unterminated flow collection');
  result.push(text.slice(start).trim());
  return result.filter((value) => value !== '');
}

function decodeQuoted(value, line) {
  if (value.startsWith('"')) {
    try {
      return JSON.parse(value);
    } catch {
      parseError(line, 'invalid double-quoted scalar');
    }
  }
  if (!value.endsWith("'")) parseError(line, 'invalid single-quoted scalar');
  return value.slice(1, -1).replace(/''/g, "'");
}

class WorkflowYamlParser {
  constructor(source) {
    this.anchors = new Map();
    this.lines = source.replace(/\r\n/g, '\n').split('\n').map((raw, offset) => {
      if (/\t/.test(raw.slice(0, raw.search(/[^\t ]|$/)))) parseError(offset + 1, 'tab indentation is unsupported');
      const stripped = stripComment(raw);
      return {
        indent: (stripped.match(/^ */) || [''])[0].length,
        line: offset + 1,
        text: stripped.trim(),
      };
    });
    this.index = 0;
  }

  current() {
    while (this.index < this.lines.length && this.lines[this.index].text === '') this.index += 1;
    return this.lines[this.index];
  }

  parse() {
    while (this.current()?.text === '---') this.index += 1;
    const current = this.current();
    if (!current) return {};
    const value = this.parseNode(current.indent);
    while (this.current()?.text === '...') this.index += 1;
    if (this.current()) parseError(this.current().line, 'multiple documents are unsupported');
    return value;
  }

  parseNode(indent) {
    const current = this.current();
    if (!current) return null;
    if (current.indent !== indent) parseError(current.line, 'unexpected indentation');
    return current.text === '-' || current.text.startsWith('- ') ? this.parseSequence(indent) : this.parseMapping(indent);
  }

  decodeKey(raw, line) {
    if (raw.startsWith('"') || raw.startsWith("'")) return String(decodeQuoted(raw, line));
    if (raw !== '<<' && !/^[A-Za-z0-9_.\-/]+$/.test(raw)) parseError(line, 'unsupported mapping key');
    return raw;
  }

  consumeAnchor(value, line) {
    if (!value.startsWith('&')) return { value };
    const match = value.match(/^&([A-Za-z][A-Za-z0-9_-]*)(?:\s+(.*))?$/);
    if (!match) parseError(line, 'invalid anchor');
    return { anchor: match[1], value: match[2] || '' };
  }

  decodeScalar(value, line) {
    if (value.startsWith('&')) {
      const anchored = this.consumeAnchor(value, line);
      const decoded = this.decodeScalar(anchored.value, line);
      this.anchors.set(anchored.anchor, clone(decoded));
      return decoded;
    }
    if (value.startsWith('*')) {
      const name = value.slice(1).trim();
      if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(name) || !this.anchors.has(name)) parseError(line, 'unknown alias');
      return clone(this.anchors.get(name));
    }
    if (value.startsWith('!')) parseError(line, 'YAML tags are unsupported');
    if (value.startsWith('"') || value.startsWith("'")) return decodeQuoted(value, line);
    if (value.startsWith('[')) {
      if (!value.endsWith(']')) parseError(line, 'unterminated flow sequence');
      return splitFlow(value.slice(1, -1), line).map((entry) => this.decodeScalar(entry, line));
    }
    if (value.startsWith('{')) {
      if (!value.endsWith('}')) parseError(line, 'unterminated flow mapping');
      const mapping = {};
      for (const entry of splitFlow(value.slice(1, -1), line)) {
        const [rawKey, rawValue] = splitMapping(entry, line);
        const key = this.decodeKey(rawKey, line);
        if (Object.hasOwn(mapping, key)) parseError(line, `duplicate mapping key ${key}`);
        mapping[key] = this.decodeScalar(rawValue, line);
      }
      return mapping;
    }
    if (value === 'null' || value === '~') return null;
    if (value === 'true') return true;
    if (value === 'false') return false;
    if (/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/.test(value)) return Number(value);
    return value;
  }

  parseValue(rawValue, parentIndent, line) {
    const { anchor, value } = this.consumeAnchor(rawValue, line);
    let decoded;
    const blockStyle = /^[>|][+-]?$/.test(value) ? value[0] : undefined;
    if (value === '' || blockStyle) {
      const next = this.current();
      if (blockStyle) {
        const blockIndent = next && next.indent > parentIndent ? next.indent : parentIndent + 2;
        const block = [];
        while (this.current() && this.current().indent >= blockIndent) {
          const entry = this.lines[this.index];
          block.push(entry.text);
          this.index += 1;
        }
        decoded = blockStyle === '|' ? `${block.join('\n')}\n` : `${block.join(' ')}\n`;
      } else if (next && next.indent > parentIndent) {
        decoded = this.parseNode(next.indent);
      } else {
        decoded = null;
      }
    } else {
      decoded = this.decodeScalar(value, line);
    }
    if (anchor) this.anchors.set(anchor, clone(decoded));
    return decoded;
  }

  assign(mapping, key, value, line) {
    if (key === '<<') {
      const sources = Array.isArray(value) ? value : [value];
      for (const source of sources) {
        if (!source || Array.isArray(source) || typeof source !== 'object') parseError(line, 'merge alias must resolve to a mapping');
        for (const [sourceKey, sourceValue] of Object.entries(source)) {
          if (!Object.hasOwn(mapping, sourceKey)) mapping[sourceKey] = clone(sourceValue);
        }
      }
      return;
    }
    if (Object.hasOwn(mapping, key)) parseError(line, `duplicate mapping key ${key}`);
    mapping[key] = value;
  }

  parseMapping(indent, initial = {}) {
    const mapping = initial;
    while (this.current() && this.current().indent === indent && !(this.current().text === '-' || this.current().text.startsWith('- '))) {
      const current = this.current();
      const [rawKey, rawValue] = splitMapping(current.text, current.line);
      const key = this.decodeKey(rawKey, current.line);
      this.index += 1;
      const value = this.parseValue(rawValue, indent, current.line);
      this.assign(mapping, key, value, current.line);
    }
    return mapping;
  }

  parseSequence(indent) {
    const sequence = [];
    while (this.current() && this.current().indent === indent && (this.current().text === '-' || this.current().text.startsWith('- '))) {
      const current = this.current();
      const remainder = current.text === '-' ? '' : current.text.slice(2).trim();
      this.index += 1;
      if (remainder === '') {
        const next = this.current();
        sequence.push(next && next.indent > indent ? this.parseNode(next.indent) : null);
        continue;
      }
      let mappingEntry;
      try {
        const [rawKey, rawValue] = splitMapping(remainder, current.line);
        mappingEntry = {};
        const key = this.decodeKey(rawKey, current.line);
        const value = this.parseValue(rawValue, indent, current.line);
        this.assign(mappingEntry, key, value, current.line);
        const next = this.current();
        if (next && next.indent > indent) this.parseMapping(next.indent, mappingEntry);
        sequence.push(mappingEntry);
      } catch (error) {
        if (!(error instanceof Error) || !error.message.includes('expected a mapping key')) throw error;
        sequence.push(this.decodeScalar(remainder, current.line));
      }
    }
    return sequence;
  }
}

export function parseWorkflowYaml(source) {
  return new WorkflowYamlParser(source).parse();
}
