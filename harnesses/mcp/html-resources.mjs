import { constants } from 'node:fs';
import { open } from 'node:fs/promises';

export const HTML_IMAGE_LIMIT = 10 * 1024 * 1024;
export const HTML_PAGE_LIMIT = 25 * 1024 * 1024;
export const isHTMLTool = name => ['woven_html_preview', 'woven_html_render'].includes(name);

// Runs on the invoking harness's machine, before its authenticated MCP request.
// The observing Mac never opens a remote caller's absolute paths.
export async function prepareHTMLTool(name, input) {
  if (!isHTMLTool(name)) return { arguments: input };
  const html = input.html;
  if (typeof html !== 'string' || !html.trim() || html.length > 512000) throw new Error('Provide nonempty HTML up to 512,000 authored characters.');
  const pattern = /(["'`])((?:\/(?!\/)|[a-z]:[\\/])(?:(?!\1)[^\r\n]){0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\1|url\(\s*((?:\/(?!\/)|[a-z]:[\\/])[^\s"'`()]{0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\s*\)/gid;
  const references = [...html.matchAll(pattern)];
  const images = new Map(), missing = new Set();
  let size = Buffer.byteLength(html);
  for (const match of references) {
    const path = match[2] ?? match[3];
    if (!images.has(path) && !missing.has(path)) {
      let file;
      try {
        file = await open(/^[a-z]:/i.test(path) ? path.replaceAll('\\\\', '\\') : path, constants.O_RDONLY | constants.O_NONBLOCK);
        const info = await file.stat();
        if (!info.isFile()) throw new Error('Images must be regular files.');
        if (info.size > HTML_IMAGE_LIMIT) throw new RangeError('Local image exceeds 10 MiB: ' + path);
        const bytes = Buffer.alloc(HTML_IMAGE_LIMIT + 1);
        let count = 0;
        while (count < bytes.length) {
          const { bytesRead } = await file.read(bytes, count, bytes.length - count, count);
          if (!bytesRead) break;
          count += bytesRead;
        }
        if (count > HTML_IMAGE_LIMIT) throw new RangeError('Local image exceeds 10 MiB: ' + path);
        const data = bytes.subarray(0, count), mime = imageMIME(data);
        if (!mime) throw new Error('File is not an image.');
        images.set(path, `data:${mime};base64,` + data.toString('base64'));
      } catch (error) {
        if (error instanceof RangeError) throw error;
        missing.add(path);
      } finally { await file?.close(); }
    }
    if (images.has(path)) size += Buffer.byteLength(images.get(path)) - Buffer.byteLength(path);
    if (size > HTML_PAGE_LIMIT) throw new Error('The page exceeds 25 MiB after embedding images.');
  }
  if (name === 'woven_html_render' && missing.size) throw new Error('Local images could not be read as images: ' + [...missing].join(', '));
  const parts = []; let cursor = 0;
  for (const match of references) {
    const path = match[2] ?? match[3], uri = images.get(path);
    if (!uri) continue;
    const [start, end] = match.indices[2] ?? match.indices[3];
    parts.push(html.slice(cursor, start), uri); cursor = end;
  }
  parts.push(html.slice(cursor));
  return { arguments: { ...input, html: parts.join('') }, missingImages: [...missing] };
}
export function imageMIME(bytes) {
  const prefix = bytes.subarray(0, 12), latin = prefix.toString('latin1');
  if (bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) return 'image/png';
  if (latin.startsWith('\xff\xd8\xff')) return 'image/jpeg';
  if (latin.startsWith('GIF8')) return 'image/gif';
  if (latin.startsWith('\0\0\x01\0')) return 'image/x-icon';
  if (latin.startsWith('BM') && latin.slice(6, 10) === '\0\0\0\0') return 'image/bmp';
  if (latin.startsWith('RIFF') && latin.slice(8) === 'WEBP') return 'image/webp';
  if (/^ftyp(?:avif|avis|mif1)$/.test(latin.slice(4))) return 'image/avif';
  let text = bytes.subarray(0, 4096).toString('utf8').trimStart();
  while (text) {
    let token;
    if (text.startsWith('<?')) token = '?>';
    else if (text.startsWith('<!--')) token = '-->';
    if (token) {
      const end = text.indexOf(token); if (end < 0) return;
      text = text.slice(end + token.length).trimStart(); continue;
    }
    if (/^<!doctype/i.test(text)) {
      let quote, subset = 0, end;
      for (let i = 9; i < text.length; i++) {
        const char = text[i];
        if (quote) { if (char === quote) quote = undefined; }
        else if (char === '"' || char === "'") quote = char;
        else if (char === '[') subset++;
        else if (char === ']') subset--;
        else if (char === '>' && subset === 0) { end = i + 1; break; }
      }
      if (end === undefined) return;
      text = text.slice(end).trimStart(); continue;
    }
    return /^<svg[\s/>]/.test(text) ? 'image/svg+xml' : undefined;
  }
}
