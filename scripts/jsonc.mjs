export function parseJSONC(source) {
    let result = '', quoted = false, escaped = false;
    for (let i = 0; i < source.length; i++) {
        const c = source[i], next = source[i + 1];
        if (quoted) {
            result += c;
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === '"') quoted = false;
        } else if (c === '"') { quoted = true; result += c; }
        else if (c === '/' && next === '/') {
            while (i < source.length && source[i] !== '\n') i++;
            result += '\n';
        } else if (c === '/' && next === '*') {
            i += 2;
            while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) i++;
            if (i >= source.length) throw new Error('Unterminated JSON comment.');
            i++;
            result += ' ';
        } else result += c;
    }
    let cleaned = '';
    quoted = false; escaped = false;
    for (let i = 0; i < result.length; i++) {
        const c = result[i];
        if (!quoted && c === ',') {
            let next = i + 1;
            while (/\s/.test(result[next] ?? '') && next < result.length) next++;
            if (result[next] === '}' || result[next] === ']') continue;
        }
        cleaned += c;
        if (quoted) {
            if (escaped) escaped = false;
            else if (c === '\\') escaped = true;
            else if (c === '"') quoted = false;
        } else if (c === '"') quoted = true;
    }
    return JSON.parse(cleaned);
}
